//! 工作台壳主体（模块化目录结构）。
//!
//! 负责组装系统标题栏、40pt 顶栏、左右活动栏、锚点工具窗和状态栏。

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use gpui_kit::base::TextSelectionLayer;
use gpui_kit::component::command::CommandState;
use gpui_kit::component::resizable::ResizableState;
use gpui_kit::component::h_flex;
use gpui_kit::{
    AppContext as _, Context, Entity, FocusHandle, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, SharedString, Styled as _, Subscription,
    Task, Window, px,
};
use lithe_core_client::CoreClient;
use lithe_features::editor::DiagnosticItem;
use lithe_features::local_history::Snapshot;
use lithe_features::quick_open::QuickFile;
use lithe_features::{
    AgentPanel, AppSettings, EditorSurface, GitPanel, MarkdownPreview, ProjectTree, RunPanel,
    RunPanelEvent, SearchPanel, SettingsView, TerminalPanel, WelcomeView,
};
use lithe_platform::PlatformServices;
use lithe_ui::components::menu_bar::{LitheMenuBar, MenuBarEvent};
use lithe_ui::components::prompt::LithePrompt;
use lithe_ui::{current_tokens, install_theme, LitheThemeKind};

pub(crate) mod chrome;
pub(crate) mod dock;
pub(crate) mod editor;
pub(crate) mod menus;
pub(crate) mod notifications;
pub(crate) mod overlays;
pub(crate) mod status;
pub(crate) mod tabs;
pub(crate) mod terminal;
pub(crate) mod workspace;

pub(crate) use dock::{CommitHeaderAction, DockAnchor, ToolWindow};
pub(crate) use menus::BranchEntry;
pub(crate) use notifications::{NotificationEntry, NotificationKind};
pub(crate) use overlays::{PaletteMode, PromptAction};
pub(crate) use tabs::OpenTab;
pub(crate) use terminal::TerminalSplitAxis;

use crate::commit_header::CommitTab;
use crate::layout;

gpui_kit::actions!(
    lithe_workbench,
    [
        OpenProject,
        ToggleSettings,
        ToggleTheme,
        ShowGit,
        ShowSearch,
        CommandPalette,
        ToggleWrap,
        DismissOverlay,
        DismissMenu
    ]
);

#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = lithe_workbench_quick_open, no_json)]
pub struct OpenQuickFile(pub PathBuf);

#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = lithe_workbench_quick_open, no_json)]
pub struct OpenQuickOpen;

#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = lithe_workbench_history, no_json)]
pub struct RestoreHistorySnapshot(pub PathBuf);

pub(crate) const OVERLAY_CONTEXT: &str = "LitheOverlay";
pub(crate) const TOP_MENU_CONTEXT: &str = "LitheTopMenu";
pub(crate) const MENU_CONTEXT: &str = "LitheWorkbench";
pub(crate) const MEMORY_REFRESH_INTERVAL: Duration = Duration::from_secs(2);

pub struct Workbench {
    client: CoreClient,
    platform: Arc<dyn PlatformServices>,
    settings: AppSettings,
    settings_view: Option<Entity<SettingsView>>,
    settings_visible: bool,
    palette: Option<Entity<CommandState>>,
    palette_visible: bool,
    palette_mode: PaletteMode,
    history_snapshots: Vec<Snapshot>,
    history_target: Option<PathBuf>,
    prompt: Option<Entity<LithePrompt>>,
    prompt_action: Option<PromptAction>,
    pending_new_project_parent: Option<PathBuf>,
    project_tree: Entity<ProjectTree>,
    editor: Entity<EditorSurface>,
    editor_webview_visible: Option<bool>,
    editor_secondary: Option<Entity<EditorSurface>>,
    editor_secondary_webview_visible: Option<bool>,
    preview: Entity<MarkdownPreview>,
    preview_visible: bool,
    preview_generation: u64,
    welcome: Entity<WelcomeView>,
    git: Entity<GitPanel>,
    git_log: Entity<GitPanel>,
    /// 提交工具窗当前显示的分段：提交或 Stash。
    commit_tab: CommitTab,
    search: Entity<SearchPanel>,
    run_panel: Entity<RunPanel>,
    terminal: Entity<TerminalPanel>,
    terminal_webview_visible: Option<bool>,
    terminal_secondary: Option<Entity<TerminalPanel>>,
    terminal_split_axis: TerminalSplitAxis,
    terminal_secondary_webview_visible: Option<bool>,
    terminal_focus_secondary: bool,
    agent: Entity<AgentPanel>,
    active_left: ToolWindow,
    active_bottom: Option<ToolWindow>,
    active_right: Option<ToolWindow>,
    left_visible: bool,
    bottom_visible: bool,
    right_visible: bool,
    left_width: f32,
    right_width: f32,
    bottom_height: f32,
    horizontal_state: Entity<ResizableState>,
    vertical_state: Entity<ResizableState>,
    layout_root: Option<PathBuf>,
    layout_restored: bool,
    project_root: Option<PathBuf>,
    tabs: Vec<OpenTab>,
    active_tab: Option<SharedString>,
    untitled_counter: usize,
    pending_close_tab: Option<SharedString>,
    closed_tabs: Vec<PathBuf>,
    nav_back: Vec<PathBuf>,
    nav_forward: Vec<PathBuf>,
    menu_bar_visible: bool,
    quick_files: Vec<QuickFile>,
    quick_index_generation: u64,
    quick_index_running: bool,
    pending_save_as: Option<(PathBuf, PathBuf)>,
    overlay_focus: FocusHandle,
    status_message: Option<SharedString>,
    cursor_line: u32,
    cursor_column: u32,
    problems: Vec<DiagnosticItem>,
    open_generation: u64,
    _read_task: Task<()>,
    _preview_task: Task<()>,
    memory_text: SharedString,
    memory_started: bool,
    _memory_task: Task<()>,
    notifications: Vec<NotificationEntry>,
    notifications_visible: bool,
    next_notification_id: u64,
    branch: SharedString,
    branch_refresh_generation: u64,
    branch_refresh_pending: bool,
    git_change_count: usize,
    _branch_task: Task<()>,
    project_menu_visible: bool,
    recent_projects: Vec<PathBuf>,
    branch_menu_visible: bool,
    branches: Vec<BranchEntry>,
    branches_loading: bool,
    branch_error: Option<SharedString>,
    branch_generation: u64,
    _branches_task: Task<()>,
    _checkout_task: Task<()>,
    menu_bar: Entity<LitheMenuBar>,
    menu_open: bool,
    _menu_subscription: Option<Subscription>,
    menu_signature: u64,
    menu_installed: bool,
    menu_install_pending: bool,
    // 项目工具窗操作状态（对齐 Tauri 的 5 个操作按钮与窗口）
    project_search_open: bool,
    project_search_query: String,
    project_options_open: bool,
    project_show_hidden: bool,
    project_show_ignored: bool,
    project_view_dependencies: bool,
}

impl Workbench {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let settings = AppSettings::load();
        lithe_ui::i18n::set_language(&settings.language);
        install_theme(cx, theme_kind_for(&settings.theme), settings.dark);

        let platform = lithe_platform::current();
        let client = CoreClient::new();
        let recent_projects = platform.recent_projects();
        let initial_root = recent_projects.iter().find(|path| path.is_dir()).cloned();
        let has_initial_root = initial_root.is_some();
        let tree_root = initial_root.clone().unwrap_or_default();

        let project_tree = cx.new(|tree_cx| ProjectTree::new(client, tree_root.clone(), tree_cx));
        let editor = cx.new(|editor_cx| EditorSurface::new(window, editor_cx));
        let preview = cx.new(MarkdownPreview::new);
        let welcome = cx.new(|welcome_cx| WelcomeView::new(platform.clone(), welcome_cx));
        let git = cx.new(|git_cx| GitPanel::new(client, tree_root.clone(), git_cx));
        let git_log = cx.new(|git_cx| GitPanel::new_log(client, tree_root.clone(), git_cx));
        let search = cx.new(|search_cx| SearchPanel::new(client, tree_root.clone(), search_cx));
        let run_panel = cx.new(|run_cx| RunPanel::new(client, tree_root.clone(), window, run_cx));
        let terminal = cx.new(|term_cx| TerminalPanel::new(tree_root.clone(), window, term_cx));
        let agent = cx.new(|agent_cx| AgentPanel::new(tree_root.clone(), window, agent_cx));
        let horizontal_state = cx.new(|_| ResizableState::default());
        let vertical_state = cx.new(|_| ResizableState::default());

        let menu_bar = cx.new(|_| LitheMenuBar::new(Vec::new()));
        let menu_subscription = cx.subscribe(&menu_bar, |this, _, event: &MenuBarEvent, cx| match event {
            MenuBarEvent::OpenChanged(is_open) => {
                this.menu_open = *is_open;
                cx.notify();
            }
        });

        let owner = cx.weak_entity();
        let settings_view = cx.new(|settings_cx| {
            let mut view = SettingsView::new(settings.clone(), window, settings_cx);
            view.on_change({
                let owner = owner.clone();
                move |next_settings, window, cx| {
                    let _ = owner.update(cx, |this, cx| {
                        this.apply_settings(next_settings.clone(), window, cx);
                    });
                }
            });
            view
        });

        cx.subscribe(&editor, |this, _, event: &lithe_features::editor::EditorEvent, cx| {
            this.handle_editor_event(event, cx);
        })
        .detach();

        // 搜索结果点击/回车：打开文件并跳到命中行。之前这个回调没有接线，
        // 面板上的结果实际上点不开。
        {
            let owner = owner.clone();
            search.update(cx, |panel, panel_cx| {
                panel.on_open_location(move |path, line, window, cx| {
                    let _ = owner.update(cx, |this, cx| {
                        this.open_file_at_line(path, line, window, cx);
                    });
                });
                let _ = panel_cx;
            });
        }

        let mut workbench = Self {
            client,
            platform,
            settings: settings.clone(),
            settings_view: Some(settings_view),
            settings_visible: false,
            palette: None,
            palette_visible: false,
            palette_mode: PaletteMode::Commands,
            history_snapshots: Vec::new(),
            history_target: None,
            prompt: None,
            prompt_action: None,
            pending_new_project_parent: None,
            project_tree,
            editor,
            editor_webview_visible: None,
            editor_secondary: None,
            editor_secondary_webview_visible: None,
            preview,
            preview_visible: false,
            preview_generation: 0,
            welcome,
            git,
            git_log,
            commit_tab: CommitTab::Commit,
            search,
            run_panel,
            terminal,
            terminal_webview_visible: None,
            terminal_secondary: None,
            terminal_split_axis: TerminalSplitAxis::Horizontal,
            terminal_secondary_webview_visible: None,
            terminal_focus_secondary: false,
            agent,
            active_left: ToolWindow::Project,
            active_bottom: None,
            active_right: None,
            left_visible: true,
            bottom_visible: false,
            right_visible: false,
            left_width: layout::LEFT_PANEL_INITIAL_WIDTH.as_f32(),
            right_width: layout::RIGHT_PANEL_INITIAL_WIDTH.as_f32(),
            bottom_height: layout::BOTTOM_PANEL_INITIAL_HEIGHT.as_f32(),
            horizontal_state,
            vertical_state,
            layout_root: None,
            layout_restored: false,
            project_root: initial_root,
            tabs: Vec::new(),
            active_tab: None,
            untitled_counter: 0,
            pending_close_tab: None,
            closed_tabs: Vec::new(),
            nav_back: Vec::new(),
            nav_forward: Vec::new(),
            menu_bar_visible: false,
            quick_files: Vec::new(),
            quick_index_generation: 0,
            quick_index_running: false,
            pending_save_as: None,
            overlay_focus: cx.focus_handle(),
            status_message: None,
            cursor_line: 1,
            cursor_column: 1,
            problems: Vec::new(),
            open_generation: 0,
            _read_task: Task::ready(()),
            _preview_task: Task::ready(()),
            memory_text: SharedString::from("—"),
            memory_started: false,
            _memory_task: Task::ready(()),
            notifications: Vec::new(),
            notifications_visible: false,
            next_notification_id: 1,
            branch: SharedString::from("main"),
            branch_refresh_generation: 0,
            branch_refresh_pending: has_initial_root,
            git_change_count: 0,
            _branch_task: Task::ready(()),
            project_menu_visible: false,
            recent_projects,
            branch_menu_visible: false,
            branches: Vec::new(),
            branches_loading: false,
            branch_error: None,
            branch_generation: 0,
            _branches_task: Task::ready(()),
            _checkout_task: Task::ready(()),
            menu_bar,
            menu_open: false,
            _menu_subscription: Some(menu_subscription),
            menu_signature: 0,
            menu_installed: false,
            menu_install_pending: false,
            project_search_open: false,
            project_search_query: String::new(),
            project_options_open: false,
            project_show_hidden: false,
            project_show_ignored: false,
            project_view_dependencies: false,
        };

        cx.subscribe(&workbench.run_panel, |this, _, event: &RunPanelEvent, cx| match event {
            RunPanelEvent::StateChanged => cx.notify(),
            RunPanelEvent::HideRequested => {
                this.set_dock_visible(DockAnchor::Bottom, false, cx);
            }
        })
        .detach();

        workbench.apply_editor_preferences(window, cx);
        workbench
    }

    pub(crate) fn set_menu_open(&mut self, open: bool, cx: &mut Context<Self>) {
        if self.menu_open != open {
            self.menu_open = open;
            cx.notify();
        }
    }

    /// 切换提交工具窗的分段（提交 / Stash）。
    pub(crate) fn set_commit_tab(&mut self, tab: CommitTab, cx: &mut Context<Self>) {
        if self.commit_tab != tab {
            self.commit_tab = tab;
            cx.notify();
        }
    }

    fn on_action_open_project(&mut self, _: &OpenProject, window: &mut Window, cx: &mut Context<Self>) {
        self.pick_project(window, cx);
    }

    fn on_action_toggle_settings(&mut self, _: &ToggleSettings, window: &mut Window, cx: &mut Context<Self>) {
        self.toggle_settings(window, cx);
    }

    fn on_action_toggle_theme(&mut self, _: &ToggleTheme, _window: &mut Window, cx: &mut Context<Self>) {
        let dark = !self.settings.dark;
        self.settings.dark = dark;
        self.save_settings(cx);
        self.apply_theme_to_workbench(cx);
    }

    fn on_action_show_git(&mut self, _: &ShowGit, window: &mut Window, cx: &mut Context<Self>) {
        self.show_tool(ToolWindow::Changes, window, cx);
    }

    fn on_action_show_search(&mut self, _: &ShowSearch, window: &mut Window, cx: &mut Context<Self>) {
        self.show_tool(ToolWindow::Search, window, cx);
    }

    fn on_action_command_palette(&mut self, _: &CommandPalette, window: &mut Window, cx: &mut Context<Self>) {
        self.open_palette(window, cx);
    }

    fn on_action_open_quick_open(&mut self, _: &OpenQuickOpen, window: &mut Window, cx: &mut Context<Self>) {
        self.open_quick_open(window, cx);
    }

    fn on_action_open_quick_file(&mut self, action: &OpenQuickFile, window: &mut Window, cx: &mut Context<Self>) {
        let path = action.0.clone();
        self.close_palette(cx);
        self.open_file_from_tree(path, window, cx);
    }

    fn on_action_restore_history_snapshot(&mut self, action: &RestoreHistorySnapshot, _window: &mut Window, cx: &mut Context<Self>) {
        let snapshot_path = action.0.clone();
        let target = self.history_target.clone();
        self.close_palette(cx);

        let Some(target_path) = target else {
            return;
        };

        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    let content = std::fs::read(&snapshot_path)?;
                    std::fs::write(&target_path, content)?;
                    Ok::<(), std::io::Error>(())
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if let Err(error) = result {
                    this.push_notification(
                        "Local History",
                        SharedString::from(error.to_string()),
                        NotificationKind::Error,
                    );
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn on_action_toggle_wrap(&mut self, _: &ToggleWrap, window: &mut Window, cx: &mut Context<Self>) {
        self.toggle_wrap(window, cx);
    }

    fn on_action_dismiss_overlay(&mut self, _: &DismissOverlay, _window: &mut Window, cx: &mut Context<Self>) {
        self.close_overlay(cx);
    }

    fn on_action_dismiss_menu(&mut self, _: &DismissMenu, _window: &mut Window, cx: &mut Context<Self>) {
        self.close_menus(cx);
    }
}

impl Render for Workbench {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if !self.memory_started {
            self.memory_started = true;
            cx.defer_in(window, |this, window, cx| {
                this.start_memory_loop(window, cx);
                if this.branch_refresh_pending {
                    this.branch_refresh_pending = false;
                    this.refresh_branch(window, cx);
                }
            });
        }

        if !self.layout_restored {
            cx.defer_in(window, |this, _window, cx| {
                this.restore_layout(cx);
            });
        }

        let menu_signature = self.menu_state().signature();
        if !self.menu_installed || menu_signature != self.menu_signature {
            if !self.menu_install_pending {
                self.menu_install_pending = true;
                cx.defer_in(window, |this, _window, cx| this.install_menus(cx));
            }
        }

        if let Some((from, to)) = self.pending_save_as.take() {
            cx.defer_in(window, move |this, window, cx| {
                let id = this
                    .tabs
                    .iter()
                    .find(|tab| tab.absolute_path == from)
                    .map(|tab| tab.id.to_string());
                if let Some(id) = id {
                    this.close_tab_now(&id, window, cx);
                }
                this.open_file_from_tree_with_history(to, false, window, cx);
            });
        }

        let overlay_open = self.settings_visible
            || self.palette_visible
            || self.notifications_visible
            || self.prompt.is_some()
            || self.menu_open
            || self
                .pending_close_tab
                .as_ref()
                .is_some_and(|id| self.tabs.iter().any(|tab| &tab.id == id));
        let welcome_visible = self.project_root.is_none() && self.tabs.is_empty();
        let preview_active = self.preview_visible && self.active_is_markdown();
        let editor_visible = !overlay_open && !welcome_visible && !preview_active;
        let editor_secondary_visible = editor_visible && self.editor_secondary.is_some();
        let terminal_visible = !overlay_open
            && self.bottom_visible
            && self.active_bottom == Some(ToolWindow::Terminal);
        let terminal_secondary_visible = terminal_visible && self.terminal_secondary.is_some();

        if self.editor_webview_visible != Some(editor_visible) {
            self.editor_webview_visible = Some(editor_visible);
            self.editor.update(cx, |editor, editor_cx| {
                editor.set_webview_visible(editor_visible, editor_cx);
            });
        }
        if self.editor_secondary_webview_visible != Some(editor_secondary_visible) {
            if let Some(secondary) = self.editor_secondary.clone() {
                self.editor_secondary_webview_visible = Some(editor_secondary_visible);
                secondary.update(cx, |editor, editor_cx| {
                    editor.set_webview_visible(editor_secondary_visible, editor_cx);
                });
            }
        }
        if self.terminal_webview_visible != Some(terminal_visible) {
            self.terminal_webview_visible = Some(terminal_visible);
            self.terminal.update(cx, |terminal, terminal_cx| {
                terminal.set_webview_visible(terminal_visible, terminal_cx);
            });
        }
        if self.terminal_secondary_webview_visible != Some(terminal_secondary_visible) {
            if let Some(panel) = self.terminal_secondary.clone() {
                self.terminal_secondary_webview_visible = Some(terminal_secondary_visible);
                panel.update(cx, |panel, panel_cx| {
                    panel.set_webview_visible(terminal_secondary_visible, panel_cx);
                });
            }
        }

        let tokens = current_tokens(cx);

        gpui_kit::component::v_flex()
            .relative()
            .size_full()
            .min_h(px(0.))
            .bg(tokens.window)
            .text_color(tokens.primary_text)
            .key_context(MENU_CONTEXT)
            .child(TextSelectionLayer)
            .on_action(cx.listener(Self::on_action_open_project))
            .on_action(cx.listener(Self::on_action_toggle_settings))
            .on_action(cx.listener(Self::on_action_toggle_theme))
            .on_action(cx.listener(Self::on_action_show_git))
            .on_action(cx.listener(Self::on_action_show_search))
            .on_action(cx.listener(Self::on_action_command_palette))
            .on_action(cx.listener(Self::on_action_open_quick_open))
            .on_action(cx.listener(Self::on_action_open_quick_file))
            .on_action(cx.listener(Self::on_action_restore_history_snapshot))
            .on_action(cx.listener(Self::on_action_toggle_wrap))
            .on_action(cx.listener(Self::on_action_dismiss_overlay))
            .on_action(cx.listener(Self::on_action_dismiss_menu))
            .on_action(cx.listener(Self::on_action_menu_command))
            .child(self.render_title_row(window, cx))
            .child(
                h_flex()
                    .items_stretch()
                    .flex_1()
                    .min_h(px(0.))
                    .min_w(px(0.))
                    .child(self.render_activity_rail(window, cx))
                    .child(
                        gpui_kit::div()
                            .flex_1()
                            .min_h(px(0.))
                            .min_w(px(0.))
                            .child(self.render_dock_area(window, cx)),
                    )
                    .child(self.render_right_activity_rail(window, cx)),
            )
            .child(self.render_status_bar(window, cx))
            .children(self.render_top_menu(window, cx))
            .children(self.render_overlay(window, cx))
    }
}

pub(crate) fn theme_kind_for(name: &str) -> LitheThemeKind {
    match name.trim().to_ascii_lowercase().as_str() {
        "codex" => LitheThemeKind::Codex,
        "linear" => LitheThemeKind::Linear,
        _ => LitheThemeKind::Lithe,
    }
}

pub(crate) fn theme_id_for(kind: LitheThemeKind) -> &'static str {
    match kind {
        LitheThemeKind::Lithe => "lithe",
        LitheThemeKind::Codex => "codex",
        LitheThemeKind::Linear => "linear",
    }
}

pub(crate) fn theme_display_name(kind: LitheThemeKind) -> &'static str {
    match kind {
        LitheThemeKind::Lithe => "Lithe",
        LitheThemeKind::Codex => "Codex",
        LitheThemeKind::Linear => "Linear",
    }
}
