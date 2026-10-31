//! 工作台壳主体（模块化目录结构）。
//!
//! 负责组装系统标题栏、40pt 顶栏、左右活动栏、锚点工具窗和状态栏。

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use gpui_kit::App;
use gpui_kit::base::TextSelectionLayer;
use gpui_kit::component::command::CommandState;
use gpui_kit::component::h_flex;
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::menu::PopupMenu;
use gpui_kit::component::resizable::ResizableState;
use gpui_kit::{
    AnyElement, AppContext as _, Context, Entity, FocusHandle, InteractiveElement as _,
    IntoElement, KeyBinding, ParentElement as _, Pixels, Point, Render, SharedString, Styled as _,
    Subscription, Task, Window, anchored, deferred, div, px,
};
use lithe_core_client::CoreClient;
use lithe_features::editor::DiagnosticItem;
use lithe_features::local_history::Snapshot;
use lithe_features::quick_open::QuickFile;
use lithe_features::{
    AgentPanel, AppSettings, CommitDiffView, EditorSurface, GitPanel, MarkdownPreview,
    MavenOutputPanel, MavenPanel, ProjectTree, RunPanel, RunPanelEvent, SearchPanel, SettingsView,
    TerminalPanel, WelcomeView,
};
use lithe_platform::PlatformServices;
use lithe_ui::components::menu_bar::{LitheMenuBar, MenuBarEvent};
use lithe_ui::components::prompt::LithePrompt;
use lithe_ui::{LitheThemeKind, current_tokens, install_theme};

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
pub(crate) use notifications::{NotificationEntry, NotificationFilter, NotificationKind};

use notifications::ToastEntry;
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
        ToggleRunWindow,
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
    /// 中央编辑区展示的提交差异页（对齐 Tauri 打开 diff 编辑器页）。
    commit_diff: Entity<CommitDiffView>,
    commit_diff_visible: bool,
    welcome: Entity<WelcomeView>,
    git: Entity<GitPanel>,
    git_log: Entity<GitPanel>,
    /// 提交工具窗当前显示的分段：提交或 Stash。
    commit_tab: CommitTab,
    search: Entity<SearchPanel>,
    run_panel: Entity<RunPanel>,
    maven: Entity<MavenPanel>,
    maven_output: Entity<MavenOutputPanel>,
    terminal: Entity<TerminalPanel>,
    terminal_webview_visible: Option<bool>,
    terminal_secondary: Option<Entity<TerminalPanel>>,
    terminal_split_axis: TerminalSplitAxis,
    terminal_secondary_webview_visible: Option<bool>,
    terminal_focus_secondary: bool,
    /// 终端 Profile 下拉菜单是否打开。
    ///
    /// 终端正文是原生 WebView，绘制层级高于 GPUI 画布；GPUI 渲染的弹出菜单
    /// 会被它整块盖住。菜单打开期间必须隐藏终端 WebView，与命令面板、设置
    /// 面板等 GPUI 覆盖层已有的处理一致。
    terminal_profile_menu_open: bool,
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
    /// 底部工具窗高度拖动的起点：按下时的指针纵坐标和当时的 `bottom_height`。
    bottom_resize_origin: Option<(Pixels, f32)>,
    horizontal_state: Entity<ResizableState>,
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
    /// 通知中心搜索框；实体常驻，输入即过滤（对齐 Tauri `searchQuery`）。
    notification_input: Option<Entity<InputState>>,
    notification_search: String,
    notification_filter: NotificationFilter,
    /// 已折叠的日期分组标签。
    notification_collapsed_groups: Vec<String>,
    /// 详情视图当前展示的通知；None 表示列表视图。
    active_notification: Option<u64>,
    /// 「已复制」反馈当前命中的通知 id。
    copied_notification: Option<u64>,
    _notification_copied_task: Task<()>,
    _notification_subscription: Option<Subscription>,
    /// 右下角实时 toast（对齐 Tauri sonner Toaster）。
    toasts: Vec<ToastEntry>,
    /// 上次同步到项目树的活动文件，避免每帧重复触发。
    synced_tree_active: Option<Option<std::path::PathBuf>>,
    /// 是否已安排 toast 过期清理任务。
    toast_prune_pending: bool,
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
    tab_context_menu: Option<(Entity<PopupMenu>, Point<Pixels>)>,
    _tab_context_menu_subscription: Option<Subscription>,
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
        let commit_diff = cx.new(|diff_cx| CommitDiffView::new(client, diff_cx));
        // 差异页头部「关闭」回到普通编辑器内容。
        {
            let diff_owner = cx.weak_entity();
            commit_diff.update(cx, |view, _view_cx| {
                view.on_close(move |_window, cx| {
                    let _ = diff_owner.update(cx, |this, cx| this.close_commit_diff(cx));
                });
            });
        }
        let welcome = cx.new(|welcome_cx| WelcomeView::new(platform.clone(), welcome_cx));
        let git = cx.new(|git_cx| GitPanel::new(client, tree_root.clone(), git_cx));
        let git_log = cx.new(|git_cx| GitPanel::new_log(client, tree_root.clone(), git_cx));
        let search = cx.new(|search_cx| SearchPanel::new(client, tree_root.clone(), search_cx));
        let run_panel = cx.new(|run_cx| RunPanel::new(client, tree_root.clone(), window, run_cx));
        let maven = cx.new(|maven_cx| MavenPanel::new(client, tree_root.clone(), window, maven_cx));
        let maven_output =
            cx.new(|output_cx| MavenOutputPanel::new(maven.clone(), window, output_cx));
        let terminal = cx.new(|term_cx| TerminalPanel::new(tree_root.clone(), window, term_cx));
        let agent = cx.new(|agent_cx| AgentPanel::new(tree_root.clone(), window, agent_cx));
        let horizontal_state = cx.new(|_| ResizableState::default());

        let menu_bar = cx.new(|_| LitheMenuBar::new(Vec::new()));
        let menu_subscription =
            cx.subscribe(&menu_bar, |this, _, event: &MenuBarEvent, cx| match event {
                MenuBarEvent::OpenChanged(is_open) => {
                    this.menu_open = *is_open;
                    cx.notify();
                }
            });

        // 通知中心搜索框：实体随工作台常驻，输入即过滤（对齐 Tauri
        // NotificationsToolWindow 的 CommandInput）。
        let notification_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(lithe_ui::i18n::tr("Search notifications"))
        });
        let notification_subscription = cx.subscribe_in(
            &notification_input,
            window,
            |this, input, event: &InputEvent, _window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.notification_search = input.read(cx).value().to_string();
                    cx.notify();
                }
            },
        );

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
            // 设置页里的「打开 Agent 面板」跳转按钮：此前从未注册 handler，
            // 点击静默无操作。
            let open_agent_owner = owner.clone();
            view.on_open_agent(move |window, cx| {
                let _ = open_agent_owner.update(cx, |this, cx| {
                    if this.settings_visible {
                        this.toggle_settings(window, cx);
                    }
                    this.show_tool(ToolWindow::Agent, window, cx);
                });
            });
            // 保存或重新识别运行配置后刷新 Run 面板，避免两个入口读到不同列表。
            let run_panel_for_settings = run_panel.clone();
            view.on_run_configurations_changed(move |cx| {
                run_panel_for_settings.update(cx, |panel, panel_cx| panel.refresh(panel_cx));
            });
            view
        });

        cx.subscribe(
            &editor,
            |this, _, event: &lithe_features::editor::EditorEvent, cx| {
                this.handle_editor_event(event, cx);
            },
        )
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

        // 项目树点击文件：交给工作台统一的开文件链路（历史、去重、标签激活）。
        //
        // 之前这条回调没有注册，`ProjectTree::activate_row` 里 `on_open_file`
        // 恒为 `None`，点击文件行只是选中而没有打开任何东西。回调拿到的是
        // `root.join(relative)` 的绝对路径，与 `open_file_from_tree` 的入参一致。
        {
            let owner = owner.clone();
            project_tree.update(cx, |tree, _tree_cx| {
                tree.on_open_file(move |path, window, cx| {
                    let _ = owner.update(cx, |this, this_cx| {
                        this.open_file_from_tree(path, window, this_cx);
                    });
                });
            });
        }

        // Git 变更树双击行：同样复用开文件链路，不再让面板自己拼路径开编辑器。
        {
            let owner = owner.clone();
            for panel in [git.clone(), git_log.clone()] {
                panel.update(cx, |panel, _panel_cx| {
                    let owner = owner.clone();
                    panel.on_open_file(move |path, window, cx| {
                        let _ = owner.update(cx, |this, this_cx| {
                            this.open_file_from_tree(path, window, this_cx);
                        });
                    });
                });
            }
        }

        // Git 提交区的 AI 入口：开关来自设置页，齿轮跳转 AI & Commit 页。
        {
            let owner = owner.clone();
            let enabled = settings.ai_commit_enabled;
            for panel in [git.clone(), git_log.clone()] {
                panel.update(cx, |panel, panel_cx| {
                    panel.set_ai_commit_enabled(enabled, panel_cx);
                    let owner = owner.clone();
                    panel.on_open_ai_settings(move |window, cx| {
                        let _ = owner.update(cx, |this, cx| {
                            this.open_ai_commit_settings(window, cx);
                        });
                    });
                });
            }
        }

        // Git Log 标题栏的「设置」入口：跳到设置页的 Git 分类，
        // 对齐 Tauri `openSettingsDialog("git")`。
        {
            let owner = owner.clone();
            for panel in [git.clone(), git_log.clone()] {
                panel.update(cx, |panel, _panel_cx| {
                    let owner = owner.clone();
                    panel.on_open_git_settings(move |window, cx| {
                        let _ = owner.update(cx, |this, cx| {
                            this.open_git_settings(window, cx);
                        });
                    });
                });
            }
        }

        // 点 Log 里的提交改动文件：在中央编辑区打开该提交的差异
        // （对齐 Tauri `openCommitDiff` 打开 diff 编辑器页）。
        {
            let owner = owner.clone();
            for panel in [git.clone(), git_log.clone()] {
                panel.update(cx, |panel, _panel_cx| {
                    let owner = owner.clone();
                    panel.on_open_commit_diff(move |hash, path, window, cx| {
                        let _ = owner.update(cx, |this, cx| {
                            this.open_commit_diff(hash, path, window, cx);
                        });
                    });
                });
            }
        }

        cx.bind_keys([
            // 活动栏「运行」的快捷键提示写的是 Shift+F10，这里必须真的注册，
            // 否则 tooltip 会承诺一个不存在的按键。语义与活动栏点击一致：
            // 只切换底部 Run 工具窗，不启动进程。
            KeyBinding::new("shift-f10", ToggleRunWindow, Some(MENU_CONTEXT)),
        ]);

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
            commit_diff,
            commit_diff_visible: false,
            welcome,
            git,
            git_log,
            commit_tab: CommitTab::Commit,
            search,
            run_panel,
            maven,
            maven_output,
            terminal,
            terminal_webview_visible: None,
            terminal_secondary: None,
            terminal_split_axis: TerminalSplitAxis::Horizontal,
            terminal_secondary_webview_visible: None,
            terminal_focus_secondary: false,
            terminal_profile_menu_open: false,
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
            bottom_resize_origin: None,
            horizontal_state,
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
            notification_input: Some(notification_input),
            notification_search: String::new(),
            notification_filter: NotificationFilter::default(),
            notification_collapsed_groups: Vec::new(),
            active_notification: None,
            copied_notification: None,
            _notification_copied_task: Task::ready(()),
            _notification_subscription: Some(notification_subscription),
            toasts: Vec::new(),
            synced_tree_active: None,
            toast_prune_pending: false,
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
            tab_context_menu: None,
            _tab_context_menu_subscription: None,
        };

        cx.subscribe(
            &workbench.run_panel,
            |this, _, event: &RunPanelEvent, cx| match event {
                RunPanelEvent::StateChanged => cx.notify(),
                RunPanelEvent::HideRequested => {
                    this.set_dock_visible(DockAnchor::Bottom, false, cx);
                }
            },
        )
        .detach();

        // 启动前保存：Run 面板不持有编辑器，只发一个无参请求，由工作台把
        // 脏缓冲写盘。对齐 Tauri `run.store.ts` 在启动前强制
        // `saveWorkspaceBeforeLaunch`，避免“改完直接运行”跑到旧 class/旧来源。
        {
            let owner = cx.weak_entity();
            workbench.run_panel.update(cx, |panel, _panel_cx| {
                panel.on_before_launch(move |cx| {
                    let _ = owner.update(cx, |this, cx| {
                        this.save_all_before_launch(cx);
                    });
                });
            });
        }

        // Run 面板的「Edit」入口：打开设置页并落到当前配置的编辑器。
        {
            let owner = cx.weak_entity();
            workbench.run_panel.update(cx, |panel, _panel_cx| {
                panel.on_open_settings(move |configuration_id, window, cx| {
                    let _ = owner.update(cx, |this, cx| {
                        this.open_run_settings(window, cx);
                        if let Some(view) = this.settings_view.clone() {
                            let configuration_id = configuration_id.to_string();
                            view.update(cx, |view, view_cx| {
                                view.edit_run_configuration(&configuration_id, view_cx);
                            });
                        }
                    });
                });
            });
        }

        // Maven 面板回调：打开文件（pom / 诊断 / 测试失败）、切换底部输出
        // 面板、跳设置页，以及把模块 Run 请求转给运行面板。
        {
            let owner = cx.weak_entity();
            workbench.maven.update(cx, |panel, _panel_cx| {
                panel.on_open_location(open_location_with(&owner));
                let owner_for_output = owner.clone();
                panel.on_show_output(move |window, cx| {
                    let _ = owner_for_output.update(cx, |this, cx| {
                        this.show_tool(ToolWindow::MavenOutput, window, cx);
                    });
                });
                let owner_for_settings = owner.clone();
                panel.on_open_settings(move |window, cx| {
                    let _ = owner_for_settings.update(cx, |this, cx| {
                        this.open_project_settings(window, cx);
                    });
                });
                let owner_for_run = owner.clone();
                panel.on_run_module(move |reactor_path, module_path, window, cx| {
                    let _ = owner_for_run.update(cx, |this, cx| {
                        this.run_maven_module(reactor_path, module_path, window, cx);
                    });
                });
                let owner_for_close = owner.clone();
                panel.on_close(move |_window, cx| {
                    let _ = owner_for_close.update(cx, |this, cx| {
                        this.set_dock_visible(DockAnchor::Right, false, cx);
                    });
                });
            });
            workbench.maven_output.update(cx, |panel, _panel_cx| {
                panel.on_open_location(open_location_with(&owner));
                let owner_for_hide = owner.clone();
                panel.on_hide(move |_window, cx| {
                    let _ = owner_for_hide.update(cx, |this, cx| {
                        this.set_dock_visible(DockAnchor::Bottom, false, cx);
                    });
                });
            });
        }

        workbench.apply_editor_preferences(window, cx);
        // Git 分组/确认/未跟踪与隐藏路径的设置在首帧就同步到面板。
        workbench.apply_git_preferences(cx);
        workbench.apply_hidden_patterns(cx);
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

    fn on_action_open_project(
        &mut self,
        _: &OpenProject,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.pick_project(window, cx);
    }

    fn on_action_toggle_settings(
        &mut self,
        _: &ToggleSettings,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.toggle_settings(window, cx);
    }

    fn on_action_toggle_theme(
        &mut self,
        _: &ToggleTheme,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let dark = !self.settings.dark;
        self.settings.dark = dark;
        self.save_settings(cx);
        self.apply_theme_to_workbench(cx);
    }

    fn on_action_show_git(&mut self, _: &ShowGit, window: &mut Window, cx: &mut Context<Self>) {
        self.show_tool(ToolWindow::Changes, window, cx);
    }

    fn on_action_show_search(
        &mut self,
        _: &ShowSearch,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.show_tool(ToolWindow::Search, window, cx);
    }

    /// `Shift+F10` / 活动栏「运行」/ View > Run。
    ///
    /// 三者都只切换底部 Run 工具窗的可见性，**不**启动进程：对齐 Tauri
    /// `view-command-actions.ts` 的 `toggleRunPane`。真正启动是 Run 面板里的
    /// Run 按钮与菜单里的 `run.run`。
    fn on_action_toggle_run_window(
        &mut self,
        _: &ToggleRunWindow,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.toggle_tool(ToolWindow::Run, window, cx);
    }

    fn on_action_command_palette(
        &mut self,
        _: &CommandPalette,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_palette(window, cx);
    }

    fn on_action_open_quick_open(
        &mut self,
        _: &OpenQuickOpen,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_quick_open(window, cx);
    }

    fn on_action_open_quick_file(
        &mut self,
        action: &OpenQuickFile,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let path = action.0.clone();
        self.close_palette(cx);
        self.open_file_from_tree(path, window, cx);
    }

    fn on_action_restore_history_snapshot(
        &mut self,
        action: &RestoreHistorySnapshot,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
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
                        Some(SharedString::from(error.to_string())),
                        NotificationKind::Error,
                    );
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn on_action_toggle_wrap(
        &mut self,
        _: &ToggleWrap,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.toggle_wrap(window, cx);
    }

    fn on_action_dismiss_overlay(
        &mut self,
        _: &DismissOverlay,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_overlay(cx);
    }

    fn on_action_dismiss_menu(
        &mut self,
        _: &DismissMenu,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_menus(cx);
    }

    fn render_tab_context_menu(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (popup, position) = self.tab_context_menu.as_ref()?;
        let popup = popup.clone();
        let position = *position;
        Some(
            deferred(
                anchored().position(position).snap_to_window().child(
                    div()
                        .occlude()
                        .on_mouse_down_out(cx.listener(move |this, _, _, cx| {
                            if this.tab_context_menu.take().is_some() {
                                this._tab_context_menu_subscription = None;
                                cx.notify();
                            }
                        }))
                        .child(popup),
                ),
            )
            .into_any_element(),
        )
    }
}

impl Render for Workbench {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 活动标签页同步到项目树：行高亮 + 自动展开定位（对齐 Tauri 文件树）。
        {
            let active = self.active_tab_path();
            let synced = self.synced_tree_active.get_or_insert(None);
            if *synced != active {
                *synced = active.clone();
                let tree = self.project_tree.clone();
                cx.defer_in(window, move |_, window, cx| {
                    tree.update(cx, |tree, tree_cx| {
                        tree.set_active_file(active.as_deref(), window, tree_cx);
                    });
                });
            }
        }

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

        // Toast 过期清理：到点唤醒一次；渲染随时发生，先顺手清一遍。
        self.prune_expired_toasts(cx);
        if !self.toasts.is_empty() && !self.toast_prune_pending {
            let wake_in = self.next_toast_expiry_in().unwrap_or(0).max(100) + 50;
            self.toast_prune_pending = true;
            cx.spawn(async move |this, cx| {
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(wake_in))
                    .await;
                let _ = this.update(cx, |this, cx| {
                    this.toast_prune_pending = false;
                    this.prune_expired_toasts(cx);
                });
            })
            .detach();
        }

        // toast 与菜单同级：GPUI 绘制会被原生 WebView 盖住，卡片可见期间
        // 隐藏编辑器/终端 webview，保证右下角实时输出不被遮挡。
        let overlay_open = self.settings_visible
            || self.palette_visible
            || self.notifications_visible
            || !self.toasts.is_empty()
            || self.prompt.is_some()
            || self.menu_open
            || self.project_menu_visible
            || self.branch_menu_visible
            || self.terminal_profile_menu_open
            || self.tab_context_menu.is_some()
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
            .on_action(cx.listener(Self::on_action_toggle_run_window))
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
            .children(self.render_toasts(cx))
            .children(self.render_tab_context_menu(cx))
            .children(self.render_overlay(window, cx))
    }
}

/// 构造「打开文件位置」回调：有行号时跳行，否则只打开文件。
fn open_location_with(
    owner: &gpui_kit::WeakEntity<Workbench>,
) -> impl Fn(PathBuf, Option<u32>, Option<u32>, &mut Window, &mut App) + 'static {
    let owner = owner.clone();
    move |path, line, _column, window, cx| {
        let _ = owner.update(cx, |this, cx| {
            match line {
                Some(line) => this.open_file_at_line(path, line, window, cx),
                None => this.open_file_from_tree(path, window, cx),
            };
        });
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
