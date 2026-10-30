use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::resizable::{h_resizable, resizable_panel, v_resizable, ResizableState};
use gpui_kit::component::{v_flex, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, IntoElement,
    ParentElement as _, Pixels, RenderOnce as _, Styled as _, Window, div, px,
};
use lithe_ui::components::tool_window_header::ToolWindowHeader;
use lithe_ui::i18n::tr;
use lithe_ui::icons::{icon, LitheIcon};
use lithe_ui::{current_tokens, LitheMetrics};

use super::Workbench;
use crate::layout;
use crate::top_bar::{TOOL_WINDOW_HEADER_BUTTON_RADIUS, TOOL_WINDOW_HEADER_BUTTON_SIZE};
use crate::workspace_layout::{self, WorkspaceLayout};

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
/// 两者通过这个枚举传递意图，避免布局层直接拼命令。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CommitHeaderAction {
    StageAll,
    UnstageAll,
    DiscardSelected,
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
            Self::Database
            | Self::Services
            | Self::Extensions
            | Self::Agent
            | Self::Maven => DockAnchor::Right,
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
            Self::Maven => LitheIcon::Maven,
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
            Self::Maven => tr("The Maven tool window is not available in this GPUI build."),
            _ => tr("This tool window is not available in this GPUI build."),
        }
    }

    /// 工具窗是否在标题栏显示刷新按钮。
    ///
    /// Search 不在此列：搜索面板自己按查询重新搜索，标题栏刷新既不对齐 Tauri
    /// 的搜索工具窗（它没有刷新/折叠按钮），也会和面板内的搜索按钮重复。
    fn supports_refresh(self) -> bool {
        matches!(self, Self::Project | Self::Changes | Self::GitLog)
    }
}

/// 一个工具窗在它所在锚点里的状态。
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct ToolState {
    pub(super) visible: bool,
    pub(super) active: bool,
}

impl Workbench {
    pub(crate) fn set_project_view_dependencies(&mut self, dependencies: bool, cx: &mut Context<Self>) {
        self.project_view_dependencies = dependencies;
        cx.notify();
    }

    pub(crate) fn reveal_active_file_in_tree(&mut self, window: &mut Window, cx: &mut Context<Self>) {
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

    pub(crate) fn toggle_show_hidden_files(&mut self, cx: &mut Context<Self>) {
        self.project_show_hidden = !self.project_show_hidden;
        cx.notify();
    }

    pub(crate) fn toggle_show_ignored_files(&mut self, cx: &mut Context<Self>) {
        self.project_show_ignored = !self.project_show_ignored;
        cx.notify();
    }

    pub(super) fn toggle_tool(&mut self, tool: ToolWindow, window: &mut Window, cx: &mut Context<Self>) {
        let anchor = tool.anchor();
        let was_active = self.tool_state(tool).active;
        let was_visible = self.tool_state(tool).visible;

        if was_visible && was_active {
            self.set_dock_visible(anchor, false, cx);
        } else {
            self.show_tool(tool, window, cx);
        }
    }

    pub(super) fn show_tool(&mut self, tool: ToolWindow, window: &mut Window, cx: &mut Context<Self>) {
        let anchor = tool.anchor();
        match anchor {
            DockAnchor::Left => self.active_left = tool,
            DockAnchor::Bottom => self.active_bottom = Some(tool),
            DockAnchor::Right => self.active_right = Some(tool),
        }
        self.set_dock_visible(anchor, true, cx);

        if tool == ToolWindow::Terminal {
            let terminal = self.terminal.clone();
            terminal.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
        } else if tool == ToolWindow::Agent {
            let agent = self.agent.clone();
            agent.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
        }
    }

    pub(crate) fn set_dock_visible(&mut self, anchor: DockAnchor, visible: bool, cx: &mut Context<Self>) {
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
            DockAnchor::Bottom => {
                self.vertical_state = cx.new(|_| ResizableState::default());
            }
        }
    }

    pub(super) fn commit_horizontal_sizes(&mut self, sizes: &[Pixels], cx: &mut Context<Self>) {
        let mut index = 0;
        if self.left_visible {
            if let Some(width) = sizes.get(index) {
                self.left_width = width.as_f32();
            }
            index += 1;
        }
        index += 1; // editor
        if self.notifications_visible || self.right_visible {
            if let Some(width) = sizes.get(index) {
                self.right_width = width.as_f32();
            }
        }
        self.persist_layout();
        cx.notify();
    }

    pub(super) fn commit_vertical_sizes(&mut self, sizes: &[Pixels], cx: &mut Context<Self>) {
        if self.bottom_visible {
            if let Some(height) = sizes.get(1) {
                self.bottom_height = height.as_f32();
            }
        }
        self.persist_layout();
        cx.notify();
    }

    pub(super) fn persist_layout(&self) {
        let Some(root) = self.layout_root.as_deref() else {
            return;
        };
        let layout = WorkspaceLayout {
            active_left: self.active_left.id().to_string(),
            active_bottom: self.active_bottom.map(|t| t.id().to_string()),
            active_right: self.active_right.map(|t| t.id().to_string()),
            left_visible: self.left_visible,
            bottom_visible: self.bottom_visible,
            right_visible: self.right_visible,
            left_width: self.left_width,
            right_width: self.right_width,
            bottom_height: self.bottom_height,
        };
        workspace_layout::save(root, &layout);
    }

    pub(super) fn restore_layout(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.layout_root.as_deref() else {
            self.layout_restored = true;
            return;
        };
        let layout = workspace_layout::load(root);
        if let Some(tool) = ToolWindow::from_id(&layout.active_left) {
            self.active_left = tool;
        }
        self.active_bottom = layout.active_bottom.as_deref().and_then(ToolWindow::from_id);
        self.active_right = layout.active_right.as_deref().and_then(ToolWindow::from_id);
        self.left_visible = layout.left_visible;
        self.bottom_visible = layout.bottom_visible;
        self.right_visible = layout.right_visible;
        self.left_width = layout.left_width;
        self.right_width = layout.right_width;
        self.bottom_height = layout.bottom_height;
        self.horizontal_state = cx.new(|_| ResizableState::default());
        self.vertical_state = cx.new(|_| ResizableState::default());
        self.layout_restored = true;
        cx.notify();
    }

    pub(crate) fn refresh_tool(&mut self, tool: ToolWindow, window: &mut Window, cx: &mut Context<Self>) {
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
            ToolWindow::Search => {
                let root = self.project_root.clone().unwrap_or_default();
                self.search.update(cx, |panel, panel_cx| {
                    panel.set_root(root, window, panel_cx);
                });
            }
            _ => {}
        }
    }

    /// 提交工具窗标题栏操作菜单的转发入口。
    ///
    /// 标题栏只负责呈现，真正的 Git 写操作仍由 `GitPanel` 拥有；这里把菜单
    /// 请求转给同一个实体，避免在布局层复制业务规则。
    pub(crate) fn commit_header_action(&mut self, action: CommitHeaderAction, cx: &mut Context<Self>) {
        self.git.update(cx, |panel, panel_cx| match action {
            CommitHeaderAction::StageAll => panel.stage_all_changes(panel_cx),
            CommitHeaderAction::UnstageAll => panel.unstage_all_changes(panel_cx),
            CommitHeaderAction::DiscardSelected => panel.discard_selected_change(panel_cx),
        });
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
                self.project_show_ignored,
                self.project_view_dependencies,
                window,
                cx,
            ))
        } else if tool == ToolWindow::Changes {
            Some(crate::commit_header::render_commit_tool_header(
                self.commit_tab,
                tokens,
                cx.weak_entity(),
                cx,
            ))
        } else {
            Some(self.render_tool_header(tool, window, cx))
        };
        let header_is_none = header.is_none();
        let content = self.render_tool_content(tool, cx);

        v_flex()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .rounded(px(LitheMetrics::PANE_RADIUS))
            .bg(tokens.editor)
            .children(header)
            .child(
                div()
                    .flex_1()
                    .min_h(px(0.))
                    .min_w(px(0.))
                    // 没有标题栏时内容区自己补上顶部圆角，保持与其它工具窗一致。
                    .when(header_is_none, |this| this.rounded_t(px(LitheMetrics::PANE_RADIUS)))
                    .rounded_b(px(LitheMetrics::PANE_RADIUS))
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

    pub(super) fn render_tool_content(&self, tool: ToolWindow, cx: &mut Context<Self>) -> AnyElement {
        match tool {
            ToolWindow::Project => self.project_tree.clone().into_any_element(),
            ToolWindow::Changes => {
                if self.commit_tab == crate::commit_header::CommitTab::Stash {
                    self.render_stash_placeholder(cx)
                } else {
                    self.git.clone().into_any_element()
                }
            }
            ToolWindow::GitLog => self.git_log.clone().into_any_element(),
            ToolWindow::Search => self.search.clone().into_any_element(),
            ToolWindow::Problems => self.render_problems(cx),
            ToolWindow::Terminal => self.render_terminal_content(cx),
            ToolWindow::Agent => self.agent.clone().into_any_element(),
            ToolWindow::Run => self.run_panel.clone().into_any_element(),
            ToolWindow::PullRequests
            | ToolWindow::References
            | ToolWindow::Spring
            | ToolWindow::Tests
            | ToolWindow::Debug
            | ToolWindow::BuildOutput
            | ToolWindow::Database
            | ToolWindow::Services
            | ToolWindow::Extensions
            | ToolWindow::Maven => self.render_unavailable_tool(tool, cx),
        }
    }

    pub(super) fn render_unavailable_tool(&self, tool: ToolWindow, cx: &mut Context<Self>) -> AnyElement {
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

    /// Stash 分段占位。Core 尚未暴露 stash 列表命令，这里明确说明未接入，
    /// 不伪造列表内容。
    pub(super) fn render_stash_placeholder(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        v_flex()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .items_center()
            .justify_center()
            .px(px(16.))
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Stash is not available in this build yet")),
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
            horizontal = horizontal.child(
                resizable_panel()
                    .size(px(self.left_width))
                    .size_range(layout::LEFT_PANEL_MIN_WIDTH..layout::LEFT_PANEL_MAX_WIDTH)
                    .child(
                        div()
                            .size_full()
                            .pr(px(6.))
                            .child(self.render_dock_panel(self.active_left, window, cx)),
                    ),
            );
        }

        horizontal = horizontal.child(
            resizable_panel()
                .size_range(layout::EDITOR_MIN_WIDTH..layout::EDITOR_MAX_WIDTH)
                .child(self.render_editor_area(window, cx)),
        );

        if self.notifications_visible {
            horizontal = horizontal.child(
                resizable_panel()
                    .size(px(self.right_width))
                    .size_range(layout::RIGHT_PANEL_MIN_WIDTH..layout::RIGHT_PANEL_MAX_WIDTH)
                    .child(
                        div()
                            .size_full()
                            .pl(px(6.))
                            .child(self.render_notifications_panel(window, cx)),
                    ),
            );
        } else if self.right_visible {
            if let Some(tool) = self.active_right {
                horizontal = horizontal.child(
                    resizable_panel()
                        .size(px(self.right_width))
                        .size_range(layout::RIGHT_PANEL_MIN_WIDTH..layout::RIGHT_PANEL_MAX_WIDTH)
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

    pub(super) fn render_dock_area(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let owner = cx.weak_entity();
        let mut vertical = v_resizable(layout::VERTICAL_GROUP_ID)
            .with_state(&self.vertical_state)
            .on_resize(move |state, _window, cx| {
                let sizes = state.read(cx).sizes().clone();
                let _ = owner.update(cx, |this, cx| {
                    this.commit_vertical_sizes(&sizes, cx);
                });
            })
            .child(resizable_panel().child(self.render_top_row(window, cx)));

        if self.bottom_visible {
            if let Some(tool) = self.active_bottom {
                vertical = vertical.child(
                    resizable_panel()
                        .size(px(self.bottom_height))
                        .size_range(
                            layout::BOTTOM_PANEL_MIN_HEIGHT..layout::BOTTOM_PANEL_MAX_HEIGHT,
                        )
                        .child(
                            div()
                                .size_full()
                                .pt(px(6.))
                                .child(self.render_dock_panel(tool, window, cx)),
                        ),
                );
            }
        }

        div()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .p(px(4.))
            .child(vertical)
            .into_any_element()
    }
}
