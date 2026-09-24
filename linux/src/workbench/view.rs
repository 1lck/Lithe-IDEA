//! 工作台集成层：装配各区域视图、订阅事件、处理快捷键与布局调整。
//!
//! 结构对齐 Tauri `MainLayout`：顶栏 / 多项目标签条 / 活动栏 + 侧边栏 + 编辑区 +
//! 右侧插件活动栏 / 底部面板 / 状态栏；无项目时显示欢迎页，浮层由模态状态控制。

use gpui_kit::component::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, FocusHandle, InteractiveElement as _, IntoElement,
    KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, ParentElement as _,
    Render, Styled as _, Subscription, Window,
};

use crate::core::CoreClient;
use crate::settings;
use crate::theme::ThemeColors;
use crate::workbench::activity_rail::{
    ActivityRailEvent, ActivityRailView, PluginActivityRailView, PluginRailEvent,
};
use crate::workbench::bottom_panel::{BottomPanelView, BottomTab};
use crate::workbench::branch_manager::{BranchManagerEvent, BranchManagerView};
use crate::workbench::command_palette::{CommandPaletteEvent, CommandPaletteModal};
use crate::workbench::editor::EditorView;
use crate::workbench::extensions_panel::{ExtensionsEvent, ExtensionsView};
use crate::workbench::go_to_line::{GoToLineEvent, GoToLineModal};
use crate::workbench::maven::{MavenEvent, MavenView};
use crate::workbench::notifications::{NotificationsEvent, NotificationsView};
use crate::workbench::project_dialog::{ProjectDialog, ProjectDialogEvent, ProjectDialogMode};
use crate::workbench::quick_open::{QuickOpenEvent, QuickOpenModal};
use crate::workbench::search_everywhere::{SearchEverywhereEvent, SearchEverywhereModal};
use crate::workbench::settings_dialog::{SettingsCategory, SettingsDialog, SettingsEvent};
use crate::workbench::sidebar::{FileEntry, SidebarEvent, SidebarTab, SidebarView};
use crate::workbench::status_bar::{StatusBarEvent, StatusBarView};
use crate::workbench::toolbar::{ToolbarEvent, ToolbarView};
use crate::workbench::welcome_screen::{WelcomeEvent, WelcomeScreenView};

/// 右侧工具窗口当前视图，对齐 Tauri `activeRightSidebarView`
///（`notifications` / `maven` / 扩展）。`None` 即隐藏，不持久化，重启丢失。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RightToolView {
    Notifications,
    Maven,
    Extensions,
}

/// 主工作台视图。
pub struct WorkbenchView {
    /// 项目工作区根路径
    pub workspace_root: String,
    /// 侧边栏是否展开
    pub sidebar_visible: bool,
    /// 侧边栏宽度（支持拖拽调节）
    pub sidebar_width: f32,
    /// 底部面板高度（支持拖拽调节）
    pub bottom_panel_height: f32,
    /// 是否正在调节侧边栏宽度
    pub is_resizing_sidebar: bool,
    /// 是否正在调节底部面板高度
    pub is_resizing_bottom_panel: bool,
    drag_start_x: f32,
    drag_start_y: f32,
    initial_resize_size: f32,

    /// 是否显示欢迎页（无打开项目时）
    pub show_welcome: bool,
    /// 全局搜索弹窗浮层是否可见
    pub show_search_everywhere: bool,
    /// 快速打开浮层是否可见
    pub show_quick_open: bool,
    /// 跳转到行浮层是否可见
    pub show_go_to_line: bool,
    /// 命令面板浮层是否可见
    pub show_command_palette: bool,
    /// 设置模态对话框是否可见
    pub show_settings_dialog: bool,
    /// 新建/克隆项目对话框是否可见
    pub show_project_dialog: bool,
    /// 分支管理器弹窗是否可见
    pub show_branch_manager: bool,
    /// 右侧工具窗口当前视图（`None` 隐藏，对齐 Tauri 右侧不持久化语义）
    pub right_tool: Option<RightToolView>,

    /// 顶部标题栏/工具栏
    pub toolbar: Entity<ToolbarView>,
    /// 左侧垂直活动栏 (Activity Rail)
    pub activity_rail: Entity<ActivityRailView>,
    /// 右侧插件活动栏 (Extensions / Notifications / Maven)
    pub plugin_rail: Entity<PluginActivityRailView>,
    /// 右侧 Maven 导航工具窗口实体
    pub maven: Entity<MavenView>,
    /// 右侧通知工具窗口实体（隐藏时保活）
    pub notifications: Entity<NotificationsView>,
    /// 右侧扩展面板实体（隐藏时保活）
    pub extensions: Entity<ExtensionsView>,
    /// 通知诊断行点击后的待跳转行号（1 起，文件加载完成后在 render 应用）
    pending_goto_line: Option<u32>,
    /// 侧边栏面板 (Files / Git / Search)
    pub sidebar: Entity<SidebarView>,
    /// 主代码编辑器区
    pub editor: Entity<EditorView>,
    /// 底部抽屉面板 (Terminal / Diagnostics，对齐 Tauri BottomPaneTab)
    pub bottom_panel: Entity<BottomPanelView>,
    /// 底部状态栏 (Status Bar)
    pub status_bar: Entity<StatusBarView>,
    /// 全局搜索弹窗
    pub search_everywhere: Entity<SearchEverywhereModal>,
    /// 快速打开弹窗
    pub quick_open: Entity<QuickOpenModal>,
    /// 跳转到行弹窗
    pub go_to_line: Entity<GoToLineModal>,
    /// 命令面板
    pub command_palette: Entity<CommandPaletteModal>,
    /// 设置模态对话框
    pub settings_dialog: Entity<SettingsDialog>,
    /// 新建/克隆项目对话框
    pub project_dialog: Entity<ProjectDialog>,
    /// 分支管理器弹窗（对齐 Tauri `GitBranchManager`）
    pub branch_manager: Entity<BranchManagerView>,
    /// 欢迎页
    pub welcome_screen: Entity<WelcomeScreenView>,

    focus_handle: FocusHandle,
    client: CoreClient,
    _subscriptions: Vec<Subscription>,
}

impl WorkbenchView {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let workspace_root = std::env::current_dir()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        Self::with_root(workspace_root, window, cx)
    }

    pub fn with_root(workspace_root: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let root = workspace_root.clone();

        let toolbar = cx.new(|_cx| ToolbarView::new(&root));
        let activity_rail = cx.new(|cx| ActivityRailView::new(cx));
        let plugin_rail = cx.new(|_cx| PluginActivityRailView::new());
        let sidebar = cx.new(|cx| SidebarView::new(root.clone(), cx));
        let editor = cx.new(|cx| EditorView::new(root.clone(), window, cx));
        let bottom_panel = cx.new(|cx| BottomPanelView::new(root.clone(), cx));
        let status_bar = cx.new(|_cx| StatusBarView::new());
        let search_everywhere = cx.new(|cx| SearchEverywhereModal::new(cx));
        let quick_open = cx.new(|cx| QuickOpenModal::new(cx));
        let go_to_line = cx.new(|cx| GoToLineModal::new(cx));
        let command_palette = cx.new(|cx| CommandPaletteModal::new(cx));
        let settings_dialog = cx.new(|cx| SettingsDialog::new(cx));
        let project_dialog = cx.new(|cx| ProjectDialog::new(cx));
        let branch_manager_root = root.clone();
        let branch_manager = cx.new(|cx| BranchManagerView::new(branch_manager_root, cx));
        let welcome_screen = cx.new(|cx| WelcomeScreenView::new(cx));
        let maven = cx.new(|cx| MavenView::new(root.clone(), cx));
        let notifications = cx.new(|cx| NotificationsView::new(cx));
        let extensions = cx.new(|cx| ExtensionsView::new(cx));
        let focus_handle = cx.focus_handle();

        // 1. 订阅侧边栏事件（打开文件、新建文件、提交 Git）
        let status_bar_clone = status_bar.clone();
        let sub_sidebar =
            cx.subscribe(
                &sidebar,
                move |this, sidebar, event: &SidebarEvent, cx| match event {
                    SidebarEvent::OpenFile(path) => {
                        this.open_file(path, cx);
                        let _ = status_bar_clone.update(cx, |sb, cx| {
                            sb.set_file_info(
                                Some(path.clone()),
                                1,
                                1,
                                EditorView::language_name(path).to_string(),
                                cx,
                            );
                        });
                    }
                    SidebarEvent::NewFile => {
                        let _ = this.editor.update(cx, |ed, cx| {
                            ed.open_file("untitled.txt".to_string(), String::new(), cx);
                        });
                        let _ = status_bar_clone.update(cx, |sb, cx| {
                            sb.set_file_info(
                                Some("untitled.txt".to_string()),
                                1,
                                1,
                                "Plain Text".to_string(),
                                cx,
                            );
                        });
                    }
                    SidebarEvent::Commit(msg) => {
                        let cmd = format!("git commit -m \"{}\"", msg);
                        this.send_terminal_command(&cmd, cx);
                        let _ = sidebar.update(cx, |sb, cx| {
                            sb.refresh_git(cx);
                        });
                    }
                },
            );

        // 2. 观察侧边栏状态变化（分支同步、文件快照同步给全局搜索与快速打开）
        let toolbar_branch_sync = toolbar.clone();
        let status_bar_branch_sync = status_bar.clone();
        let search_sync = search_everywhere.clone();
        let quick_open_sync = quick_open.clone();
        let status_bar_git_sync = status_bar.clone();
        let plugin_rail_maven = plugin_rail.clone();
        let obs_sidebar = cx.observe(&sidebar, move |this, sidebar, cx| {
            let branch = sidebar.read(cx).git_branch.clone();
            let _ = toolbar_branch_sync.update(cx, |tb, cx| {
                tb.set_git_branch(branch.clone(), cx);
            });
            let _ = status_bar_branch_sync.update(cx, |sb, cx| {
                sb.set_git_branch(branch, cx);
            });
            let _ = status_bar_git_sync.update(cx, |sb, cx| {
                sb.set_git_changes(sidebar.read(cx).git_changes.len(), cx);
            });

            // 收集所有文件供全局搜索与快速打开
            let mut file_list = Vec::new();
            if let Some(root_node) = &sidebar.read(cx).root_node {
                Self::collect_all_file_paths(root_node, &mut file_list);
            }
            if !file_list.is_empty() {
                let _ = search_sync.update(cx, |search, cx| {
                    search.set_files(file_list.clone(), cx);
                });
                let _ = quick_open_sync.update(cx, |qo, cx| {
                    qo.set_files(file_list, cx);
                });
            }
            // 已打开标签页同步给快速打开置顶分组（对齐 Tauri `openBufferFiles`）。
            let open_files: Vec<String> = this
                .editor
                .read(cx)
                .tabs
                .iter()
                .map(|tab| tab.path.clone())
                .collect();
            if !open_files.is_empty() {
                let _ = quick_open_sync.update(cx, |qo, cx| {
                    qo.set_open_files(open_files, cx);
                });
            }

            // 同步 Maven 可用性：有 pom 项目时右侧插件栏才显示 Maven 入口。
            let has_maven = this.maven.read(cx).has_projects();
            let _ = plugin_rail_maven.update(cx, |r, cx| {
                r.maven_available = has_maven;
                cx.notify();
            });
        });

        // 3. 订阅左侧活动栏事件
        let sidebar_clone = sidebar.clone();
        let bottom_panel_clone = bottom_panel.clone();
        let sub_rail = cx.subscribe(
            &activity_rail,
            move |this, rail, event: &ActivityRailEvent, cx| match event {
                ActivityRailEvent::SelectView(view_id) => {
                    let was_active = this.sidebar_visible
                        && rail.read(cx).active_view.as_deref() == Some(view_id);

                    if was_active {
                        this.sidebar_visible = false;
                        let _ = rail.update(cx, |r, cx| r.set_active_view(None, cx));
                    } else {
                        this.sidebar_visible = true;
                        let _ =
                            rail.update(cx, |r, cx| r.set_active_view(Some(view_id.clone()), cx));
                        if let Some(tab) = sidebar_tab_for(view_id) {
                            let _ = sidebar_clone.update(cx, |sb, cx| sb.set_tab(tab, cx));
                        }
                    }
                    cx.notify();
                }
                ActivityRailEvent::ToggleBottomPane(pane_id) => {
                    let target = bottom_tab_for(pane_id);
                    let collapsed = bottom_panel_clone.read(cx).is_collapsed;
                    let already = !collapsed
                        && target.is_some()
                        && bottom_panel_clone.read(cx).active_tab == target.unwrap();
                    if already {
                        let _ = bottom_panel_clone.update(cx, |bp, cx| bp.toggle_collapsed(cx));
                        let _ = rail.update(cx, |r, cx| r.set_active_bottom(None, cx));
                    } else {
                        if let Some(tab) = target {
                            let _ = bottom_panel_clone.update(cx, |bp, cx| bp.set_tab(tab, cx));
                        }
                        let _ =
                            rail.update(cx, |r, cx| r.set_active_bottom(Some(pane_id.clone()), cx));
                    }
                    cx.notify();
                }
                ActivityRailEvent::OpenSettings => {
                    this.open_settings(cx);
                }
            },
        );

        // 4. 订阅右侧插件活动栏事件
        let sub_plugin_rail = cx.subscribe(
            &plugin_rail,
            |this, _rail, event: &PluginRailEvent, cx| match event {
                PluginRailEvent::OpenExtensions => {
                    this.toggle_right_tool(RightToolView::Extensions, cx);
                }
                PluginRailEvent::ToggleNotifications => {
                    this.toggle_right_tool(RightToolView::Notifications, cx);
                }
                PluginRailEvent::ToggleMaven => {
                    this.toggle_right_tool(RightToolView::Maven, cx);
                }
            },
        );

        // 4b-1. 订阅通知面板事件（关闭、诊断行跳转文件）
        let sub_notifications = cx.subscribe(
            &notifications,
            |this, _view, event: &NotificationsEvent, cx| match event {
                NotificationsEvent::Close => {
                    this.right_tool = None;
                    cx.notify();
                }
                NotificationsEvent::OpenFile(path, line) => {
                    this.pending_goto_line = Some(*line);
                    this.open_file(path, cx);
                }
            },
        );

        // 4b-2. 订阅扩展面板事件（关闭）
        let sub_extensions = cx.subscribe(
            &extensions,
            |this, _view, event: &ExtensionsEvent, cx| match event {
                ExtensionsEvent::Close => {
                    this.right_tool = None;
                    cx.notify();
                }
            },
        );

        // 4b. 订阅 Maven 视图事件（执行目标、关闭工具窗口）
        let sub_maven = cx.subscribe(&maven, |this, _maven, event: &MavenEvent, cx| match event {
            MavenEvent::RunGoal { pom_path, phase } => {
                let cmd = format!("mvn -f \"{pom_path}\" {phase}");
                this.send_terminal_command(&cmd, cx);
            }
            MavenEvent::Close => {
                this.right_tool = None;
                cx.notify();
            }
        });

        // 5. 订阅顶部工具栏事件
        let sub_toolbar =
            cx.subscribe(
                &toolbar,
                |this, _toolbar, event: &ToolbarEvent, cx| match event {
                    ToolbarEvent::NewFile => {
                        let _ = this.editor.update(cx, |ed, cx| {
                            ed.open_file("untitled.txt".to_string(), String::new(), cx);
                        });
                    }
                    ToolbarEvent::Save => {
                        let _ = this.editor.update(cx, |ed, cx| {
                            ed.save_active(cx);
                        });
                    }
                    ToolbarEvent::CloseTab => {
                        let _ = this.editor.update(cx, |ed, cx| {
                            if let Some(idx) = ed.active_tab_index {
                                ed.close_tab(idx, cx);
                            }
                        });
                    }
                    ToolbarEvent::ToggleSidebar => {
                        this.toggle_sidebar(cx);
                    }
                    ToolbarEvent::ToggleTerminal => {
                        let _ = this.bottom_panel.update(cx, |bp, cx| {
                            bp.toggle_collapsed(cx);
                        });
                    }
                    ToolbarEvent::ClearTerminal => {
                        let _ = this.bottom_panel.update(cx, |bp, cx| {
                            let _ = bp.terminal.update(cx, |term, cx| {
                                term.clear(cx);
                            });
                        });
                    }
                    ToolbarEvent::RefreshWorkspace => {
                        let _ = this.sidebar.update(cx, |sb, cx| {
                            sb.refresh(cx);
                            sb.refresh_git(cx);
                        });
                    }
                    ToolbarEvent::QuickOpen => {
                        this.open_quick_open(cx);
                    }
                    ToolbarEvent::Run => {
                        this.send_terminal_command("echo '[Lithe Run]' && cargo check", cx);
                    }
                    ToolbarEvent::Debug => {
                        this.append_log("[Debug] Launching DAP debug session...", cx);
                    }
                    ToolbarEvent::Stop => {
                        this.append_log("[Stop] Session terminated by user.", cx);
                    }
                    ToolbarEvent::OpenSettings => {
                        this.open_settings(cx);
                    }
                    ToolbarEvent::About => {
                        this.append_log(
                            "[About] Lithe IDE for Linux (Powered by GPUI Kit & Rust Core)",
                            cx,
                        );
                    }
                    ToolbarEvent::Exit | ToolbarEvent::WindowClose => {
                        cx.quit();
                    }
                    ToolbarEvent::ToggleTheme => {
                        this.toggle_theme(cx);
                    }
                    ToolbarEvent::WindowMinimize => {
                        cx.defer(|cx| {
                            if let Some(handle) = cx.active_window() {
                                let _ = handle.update(cx, |_, window, _| window.minimize_window());
                            }
                        });
                    }
                    ToolbarEvent::WindowMaximize => {
                        cx.defer(|cx| {
                            if let Some(handle) = cx.active_window() {
                                let _ = handle.update(cx, |_, window, _| window.zoom_window());
                            }
                        });
                    }
                    ToolbarEvent::MenuAction(id) => {
                        this.handle_action(id, cx);
                    }
                    ToolbarEvent::NewProject => {
                        let _ = this.project_dialog.update(cx, |d, cx| {
                            d.set_mode(ProjectDialogMode::New, cx);
                        });
                        this.show_project_dialog = true;
                        cx.notify();
                    }
                    ToolbarEvent::OpenProject => {
                        if let Some(dir) = ProjectDialog::pick_folder(None) {
                            this.open_project_path(dir, cx);
                        }
                    }
                    ToolbarEvent::CloneRepository => {
                        let _ = this.project_dialog.update(cx, |d, cx| {
                            d.set_mode(ProjectDialogMode::Clone, cx);
                        });
                        this.show_project_dialog = true;
                        cx.notify();
                    }
                    ToolbarEvent::OpenRecent => {
                        this.show_welcome = true;
                        cx.notify();
                    }
                    ToolbarEvent::OpenRecentProject(path) => {
                        this.open_project_path(path.clone(), cx);
                    }
                    ToolbarEvent::OpenBranchManager => {
                        let root = this.workspace_root.clone();
                        let current = this.sidebar.read(cx).git_branch.clone();
                        let _ = this.branch_manager.update(cx, |bm, cx| {
                            bm.set_repo(root, current, cx);
                        });
                        this.show_branch_manager = true;
                        cx.notify();
                    }
                },
            );

        // 6. 订阅全局搜索事件
        let status_bar_search = status_bar.clone();
        let sub_search = cx.subscribe(
            &search_everywhere,
            move |this, _search, event: &SearchEverywhereEvent, cx| match event {
                SearchEverywhereEvent::OpenFile(path) => {
                    this.open_file(path, cx);
                    let _ = status_bar_search.update(cx, |sb, cx| {
                        sb.set_file_info(
                            Some(path.clone()),
                            1,
                            1,
                            EditorView::language_name(path).to_string(),
                            cx,
                        );
                    });
                    this.show_search_everywhere = false;
                    cx.notify();
                }
                SearchEverywhereEvent::ExecuteAction(action_id) => {
                    this.handle_action(action_id, cx);
                    this.show_search_everywhere = false;
                    cx.notify();
                }
                SearchEverywhereEvent::Close => {
                    this.show_search_everywhere = false;
                    cx.notify();
                }
            },
        );

        // 7. 订阅快速打开事件
        let status_bar_quick = status_bar.clone();
        let quick_open_recent = quick_open.clone();
        let sub_quick_open = cx.subscribe(
            &quick_open,
            move |this, _qo, event: &QuickOpenEvent, cx| match event {
                QuickOpenEvent::OpenFile(path) => {
                    this.open_file(path, cx);
                    let _ = status_bar_quick.update(cx, |sb, cx| {
                        sb.set_file_info(
                            Some(path.clone()),
                            1,
                            1,
                            EditorView::language_name(path).to_string(),
                            cx,
                        );
                    });
                    // 记录最近打开（对齐 Tauri `addOrUpdateRecentFile`）。
                    let recent_path = path.clone();
                    let _ = quick_open_recent.update(cx, |qo, cx| {
                        qo.push_recent(recent_path, cx);
                    });
                    this.show_quick_open = false;
                    cx.notify();
                }
                QuickOpenEvent::Close => {
                    this.show_quick_open = false;
                    cx.notify();
                }
            },
        );

        // 7b. 订阅跳转到行事件
        let sub_go_to_line = cx.subscribe(
            &go_to_line,
            move |this, _modal, event: &GoToLineEvent, cx| match event {
                GoToLineEvent::Confirm(line) => {
                    let line = *line;
                    this.show_go_to_line = false;
                    this.editor_window_action(cx, move |ed, window, cx| {
                        ed.go_to_line(line, window, cx);
                    });
                    cx.notify();
                }
                GoToLineEvent::Close => {
                    this.show_go_to_line = false;
                    cx.notify();
                }
            },
        );

        // 8. 订阅命令面板事件
        let sub_command_palette = cx.subscribe(
            &command_palette,
            |this, _cp, event: &CommandPaletteEvent, cx| match event {
                CommandPaletteEvent::Execute(id) => {
                    this.handle_action(id, cx);
                    this.show_command_palette = false;
                    cx.notify();
                }
                CommandPaletteEvent::Close => {
                    this.show_command_palette = false;
                    cx.notify();
                }
            },
        );

        // 9. 订阅设置对话框事件
        let sub_settings = cx.subscribe(
            &settings_dialog,
            |this, _dialog, event: &SettingsEvent, cx| match event {
                SettingsEvent::Close => {
                    this.show_settings_dialog = false;
                    cx.notify();
                }
                SettingsEvent::Changed => {
                    cx.notify();
                }
            },
        );

        // 9b. 订阅新建/克隆项目对话框事件
        let sub_project_dialog = cx.subscribe(
            &project_dialog,
            |this, _dialog, event: &ProjectDialogEvent, cx| match event {
                ProjectDialogEvent::OpenedProject { path, starter } => {
                    this.show_project_dialog = false;
                    this.open_project_path(path.clone(), cx);
                    if let Some(cmd) = starter {
                        this.send_terminal_command(cmd, cx);
                    }
                    cx.notify();
                }
                ProjectDialogEvent::Close => {
                    this.show_project_dialog = false;
                    cx.notify();
                }
            },
        );

        // 9c. 订阅分支管理器弹窗事件
        let sub_branch_manager = cx.subscribe(
            &branch_manager,
            |this, _bm, event: &BranchManagerEvent, cx| match event {
                BranchManagerEvent::CheckoutDone => {
                    // core 直连已完成才返回：关弹窗并重读 sidebar git 状态，
                    // 分支徽标经既有 observer 同步刷新。
                    this.show_branch_manager = false;
                    let _ = this.sidebar.update(cx, |sb, cx| {
                        sb.refresh_git(cx);
                    });
                    cx.notify();
                }
                BranchManagerEvent::OpenWorktree(path) => {
                    this.show_branch_manager = false;
                    this.open_project_path(path.clone(), cx);
                }
                BranchManagerEvent::Close => {
                    this.show_branch_manager = false;
                    cx.notify();
                }
            },
        );

        // 10. 订阅欢迎页事件
        let sub_welcome = cx.subscribe(
            &welcome_screen,
            |this, _welcome, event: &WelcomeEvent, cx| match event {
                WelcomeEvent::OpenFolder => {
                    if let Some(dir) = ProjectDialog::pick_folder(None) {
                        this.open_project_path(dir, cx);
                    }
                }
                WelcomeEvent::NewProject => {
                    let _ = this.project_dialog.update(cx, |d, cx| {
                        d.set_mode(ProjectDialogMode::New, cx);
                    });
                    this.show_project_dialog = true;
                    cx.notify();
                }
                WelcomeEvent::CloneRepository => {
                    let _ = this.project_dialog.update(cx, |d, cx| {
                        d.set_mode(ProjectDialogMode::Clone, cx);
                    });
                    this.show_project_dialog = true;
                    cx.notify();
                }
                WelcomeEvent::OpenProject(path) => {
                    this.open_project_path(path.clone(), cx);
                }
                WelcomeEvent::OpenSettings => {
                    this.open_settings(cx);
                }
                WelcomeEvent::RemoveRecent(path) => {
                    let _ = path;
                    cx.notify();
                }
            },
        );

        // 11. 订阅状态栏事件
        let sidebar_status = sidebar.clone();
        let sub_status =
            cx.subscribe(
                &status_bar,
                move |this, _sb, event: &StatusBarEvent, cx| match event {
                    StatusBarEvent::OpenGit => {
                        this.sidebar_visible = true;
                        let _ = this
                            .activity_rail
                            .update(cx, |r, cx| r.set_active_view(Some("git".to_string()), cx));
                        let _ = sidebar_status.update(cx, |sb, cx| sb.set_tab(SidebarTab::Git, cx));
                        cx.notify();
                    }
                },
            );

        // 12. 窗口外观变化：跟随系统主题时实时切换调色板
        let sub_appearance = cx.observe_window_appearance(window, |this, window, cx| {
            let sync = settings::get(cx).sync_system_theme;
            if sync {
                let is_dark = !matches!(
                    window.appearance(),
                    gpui_kit::WindowAppearance::Light | gpui_kit::WindowAppearance::VibrantLight
                );
                this.apply_resolved_theme(is_dark, cx);
            }
        });

        let mut view = Self {
            workspace_root,
            sidebar_visible: true,
            sidebar_width: settings::get(cx).sidebar_width,
            bottom_panel_height: 240.0,
            is_resizing_sidebar: false,
            is_resizing_bottom_panel: false,
            drag_start_x: 0.0,
            drag_start_y: 0.0,
            initial_resize_size: 0.0,
            show_welcome: false,
            show_search_everywhere: false,
            show_quick_open: false,
            show_go_to_line: false,
            show_command_palette: false,
            show_settings_dialog: false,
            show_project_dialog: false,
            show_branch_manager: false,
            right_tool: None,
            pending_goto_line: None,
            toolbar,
            activity_rail,
            plugin_rail,
            maven,
            notifications,
            extensions,
            sidebar,
            editor,
            bottom_panel,
            status_bar,
            search_everywhere,
            quick_open,
            go_to_line,
            command_palette,
            settings_dialog,
            project_dialog,
            branch_manager,
            welcome_screen,
            focus_handle,
            client: CoreClient::new(),
            _subscriptions: vec![
                sub_sidebar,
                obs_sidebar,
                sub_rail,
                sub_plugin_rail,
                sub_notifications,
                sub_extensions,
                sub_maven,
                sub_toolbar,
                sub_search,
                sub_quick_open,
                sub_go_to_line,
                sub_command_palette,
                sub_settings,
                sub_project_dialog,
                sub_branch_manager,
                sub_welcome,
                sub_status,
                sub_appearance,
            ],
        };

        // 应用初始主题与状态栏缩进
        let is_dark = {
            let s = settings::get(cx);
            !crate::theme::ThemePalette::is_light(&settings::resolved_theme_id(s, false))
        };
        view.apply_resolved_theme(is_dark, cx);
        // 启动目录同样记入最近项目（对齐 Tauri 打开即记录）。
        settings::record_recent_project(cx, &view.workspace_root.clone());
        // 同步工具栏当前项目行（仿分支同步写法；构造时已传入，此处再确认一次）。
        let root_for_toolbar = view.workspace_root.clone();
        let _ = view.toolbar.update(cx, |tb, cx| {
            tb.set_workspace_root(root_for_toolbar.clone(), cx);
        });
        // 构造后初始化 Maven 入口可用性，避免无 pom 目录首次打开仍显示入口。
        let maven_has_projects = view.maven.read(cx).has_projects();
        let _ = view.plugin_rail.update(cx, |r, cx| {
            r.maven_available = maven_has_projects;
            cx.notify();
        });
        let tab_size = settings::get(cx).tab_size;
        let _ = view.status_bar.update(cx, |sb, cx| {
            sb.indent_size = tab_size;
            cx.notify();
        });

        view
    }

    /// 切换侧边栏展开状态；展开时回到活动栏当前视图。
    fn toggle_sidebar(&mut self, cx: &mut Context<Self>) {
        self.sidebar_visible = !self.sidebar_visible;
        let active_view = self.activity_rail.read(cx).active_view.clone();
        if !self.sidebar_visible {
            let _ = self
                .activity_rail
                .update(cx, |r, cx| r.set_active_view(None, cx));
        } else if active_view.is_none() {
            let _ = self
                .activity_rail
                .update(cx, |r, cx| r.set_active_view(Some("files".to_string()), cx));
        }
        cx.notify();
    }

    /// 切换浅色/深色主题并落盘。
    fn toggle_theme(&mut self, cx: &mut Context<Self>) {
        let next = {
            let s = settings::get(cx);
            if s.sync_system_theme {
                // 跟随系统时，手动切换视为退出跟随并固定为相反外观。
                let current = settings::resolved_theme_id(s, false);
                if crate::theme::ThemePalette::is_light(&current) {
                    s.auto_theme_dark.clone()
                } else {
                    s.auto_theme_light.clone()
                }
            } else if crate::theme::ThemePalette::is_light(&s.theme) {
                "lithe-dark".to_string()
            } else {
                "lithe-light".to_string()
            }
        };
        let next_for_update = next.clone();
        settings::update(cx, |s| {
            s.theme = next_for_update;
            s.sync_system_theme = false;
        });
        self.apply_resolved_theme(!crate::theme::ThemePalette::is_light(&next), cx);
        cx.notify();
    }

    /// 按解析后的外观应用工作台调色板，并同步 gpui-component 主题模式。
    fn apply_resolved_theme(&mut self, system_is_dark: bool, cx: &mut Context<Self>) {
        let theme_id = {
            let s = settings::get(cx);
            settings::resolved_theme_id(s, system_is_dark)
        };
        settings::apply_theme(&theme_id);
        let mode = if crate::theme::ThemePalette::is_light(&theme_id) {
            gpui_kit::component::ThemeMode::Light
        } else {
            gpui_kit::component::ThemeMode::Dark
        };
        gpui_kit::component::Theme::change(mode, None, cx);
        cx.notify();
    }

    /// 打开设置对话框并按 `lastSettingsTab` 重置分类。
    fn open_settings(&mut self, cx: &mut Context<Self>) {
        self.show_settings_dialog = true;
        let _ = self.settings_dialog.update(cx, |d, cx| d.open(cx));
        cx.notify();
    }

    /// 切换到指定项目根路径：同步侧边栏、Maven 与欢迎页状态，并记录最近项目。
    /// 右侧工具窗口 toggle（对齐 `resolveRightToolWindowUpdate`）：
    /// 同视图再点关闭，否则切换视图并展开。
    fn toggle_right_tool(&mut self, view: RightToolView, cx: &mut Context<Self>) {
        if self.right_tool == Some(view) {
            self.right_tool = None;
        } else {
            self.right_tool = Some(view);
        }
        cx.notify();
    }

    /// 经底部终端发送命令：执行 + 计入运行历史 + 点亮左侧 maven 项
    ///（对齐 Tauri `toggleTerminalPane` 系 + `hasMavenRun` 挂载语义）。
    fn send_terminal_command(&mut self, cmd: &str, cx: &mut Context<Self>) {
        let cmd = cmd.to_string();
        let _ = self.bottom_panel.update(cx, |bp, cx| {
            bp.set_tab(BottomTab::Terminal, cx);
            let _ = bp.terminal.update(cx, |term, cx| {
                term.send_command(&cmd, cx);
            });
            bp.record_run(&cmd, cx);
        });
        let has_run = self.bottom_panel.read(cx).has_run_history();
        let _ = self.activity_rail.update(cx, |r, cx| {
            r.set_has_maven_run(has_run, cx);
        });
        cx.notify();
    }

    fn open_project_path(&mut self, path: String, cx: &mut Context<Self>) {
        if self.show_project_dialog {
            self.show_project_dialog = false;
        }
        self.workspace_root = path.clone();
        self.show_welcome = false;
        // 同步工具栏当前项目行（仿分支同步写法）。
        let _ = self.toolbar.update(cx, |tb, cx| {
            tb.set_workspace_root(path.clone(), cx);
        });
        // 记录最近项目（对齐 Tauri upsert）。
        settings::record_recent_project(cx, &path);
        let _ = self.sidebar.update(cx, |sb, cx| {
            sb.root_path = path.clone();
            sb.refresh(cx);
            sb.refresh_git(cx);
        });
        let _ = self.maven.update(cx, |m, cx| {
            m.set_root(path.clone(), cx);
        });
        let _ = self.bottom_panel.update(cx, |bp, _cx| {
            bp.working_dir = path.clone();
        });
        // 右侧通知中心投递项目打开事件（对齐 Tauri 系统事件通知）。
        let _ = self.notifications.update(cx, |n, cx| {
            n.push("已打开项目", path.clone(), cx);
        });
        cx.notify();
    }

    fn append_log(&mut self, message: &str, cx: &mut Context<Self>) {
        let _ = self.bottom_panel.update(cx, |bp, cx| {
            bp.append_log(message.to_string(), cx);
        });
    }

    /// 打开全局搜索弹窗并更新当前文件索引
    pub fn open_search_everywhere(&mut self, cx: &mut Context<Self>) {
        this_sync_files(self, cx);
        self.show_search_everywhere = true;
        let _ = self.search_everywhere.update(cx, |search, cx| {
            search.reset(cx);
        });
        cx.notify();
    }

    /// 打开快速打开弹窗
    pub fn open_quick_open(&mut self, cx: &mut Context<Self>) {
        this_sync_files(self, cx);
        self.show_quick_open = true;
        let _ = self.quick_open.update(cx, |qo, cx| {
            qo.reset(cx);
        });
        cx.notify();
    }

    /// 打开跳转到行弹窗
    pub fn open_go_to_line(&mut self, cx: &mut Context<Self>) {
        self.show_go_to_line = true;
        let _ = self.go_to_line.update(cx, |modal, cx| {
            modal.reset(cx);
        });
        cx.notify();
    }

    /// 打开命令面板
    pub fn open_command_palette(&mut self, cx: &mut Context<Self>) {
        self.show_command_palette = true;
        let _ = self.command_palette.update(cx, |cp, cx| {
            cp.reset(cx);
        });
        cx.notify();
    }

    fn collect_all_file_paths(entry: &FileEntry, output: &mut Vec<String>) {
        if !entry.is_directory {
            output.push(entry.path.clone());
        }
        if let Some(children) = &entry.children {
            for child in children {
                Self::collect_all_file_paths(child, output);
            }
        }
    }

    /// 持有 `&mut Window` 调用方的编辑器动作直达通道（按键监听等已有
    /// window 的路径使用，避免经窗口句柄二次 `update` 的重入借用失败）。
    fn editor_direct(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        action: impl FnOnce(&mut EditorView, &mut Window, &mut Context<EditorView>),
    ) {
        let _ = self.editor.update(cx, |ed, cx| action(ed, window, cx));
    }

    /// 无 `window` 上下文的编辑器动作经窗口句柄下发（菜单/面板事件路径，
    /// 非重入场景）。`active_window` 仅反映平台聚焦，Xvfb 下可能为 None，
    /// 单窗口应用退化到 `windows()` 首个句柄。
    fn editor_window_action(
        &self,
        cx: &mut Context<Self>,
        action: impl FnOnce(&mut EditorView, &mut Window, &mut Context<EditorView>) + 'static,
    ) {
        let editor = self.editor.clone();
        let handle = cx
            .active_window()
            .or_else(|| cx.windows().into_iter().next());
        if let Some(handle) = handle {
            let _ = handle.update(cx, |_, window, cx| {
                editor.update(cx, |ed, cx| action(ed, window, cx));
            });
        }
    }

    /// 在系统浏览器中打开 URL（Linux-frame：`xdg-open`，失败忽略）。
    fn open_url(url: &str) {
        let _ = std::process::Command::new("xdg-open").arg(url).spawn();
    }

    /// 另存为：存盘框选目标后落盘，并更新活动标签的 path/title。
    ///
    /// 目标在工作区内时经 core `file.write`（仿 `save_active`）；工作区外
    /// core 会拒绝绝对路径，改用 `std::fs` 直写。
    fn save_active_as(&mut self, cx: &mut Context<Self>) {
        let (old_path, text) = {
            let ed = self.editor.read(cx);
            let Some(idx) = ed.active_tab_index else {
                return;
            };
            let Some(tab) = ed.tabs.get(idx) else {
                return;
            };
            (tab.path.clone(), tab.content.clone())
        };
        let default_name = old_path
            .rsplit('/')
            .next()
            .unwrap_or("untitled.txt")
            .to_string();
        let dest = rfd::FileDialog::new()
            .set_directory(&self.workspace_root)
            .set_file_name(&default_name)
            .save_file();
        let Some(dest) = dest else {
            return;
        };
        let title = dest
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or(default_name);
        let root = self.workspace_root.clone();
        if let Ok(rel) = dest.strip_prefix(std::path::Path::new(&root)) {
            let rel = rel.to_string_lossy().to_string();
            let editor = self.editor.clone();
            let client = self.client.clone();
            cx.spawn(async move |_this, cx| {
                if client.write_file(&cx, &root, &rel, &text).await.is_ok() {
                    let _ = editor.update(cx, |ed, cx| {
                        if let Some(idx) = ed.active_tab_index {
                            if let Some(t) = ed.tabs.get_mut(idx) {
                                if t.path == old_path {
                                    t.path = rel.clone();
                                    t.title = title.clone();
                                    t.is_dirty = false;
                                    cx.notify();
                                }
                            }
                        }
                    });
                }
            })
            .detach();
        } else if std::fs::write(&dest, text.as_bytes()).is_ok() {
            let abs = dest.to_string_lossy().to_string();
            let _ = self.editor.update(cx, |ed, cx| {
                if let Some(idx) = ed.active_tab_index {
                    if let Some(t) = ed.tabs.get_mut(idx) {
                        if t.path == old_path {
                            t.path = abs;
                            t.title = title;
                            t.is_dirty = false;
                            cx.notify();
                        }
                    }
                }
            });
        }
    }

    /// 还原文件：重读活动文件内容并灌回编辑器（同路径 `open_file` 会刷新内容并清除脏标记）。
    fn revert_active_file(&mut self, cx: &mut Context<Self>) {
        let path = {
            let ed = self.editor.read(cx);
            let Some(idx) = ed.active_tab_index else {
                return;
            };
            let Some(tab) = ed.tabs.get(idx) else {
                return;
            };
            tab.path.clone()
        };
        if std::path::Path::new(&path).is_absolute() {
            if let Ok(text) = std::fs::read_to_string(&path) {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.open_file(path, text, cx);
                });
            }
            return;
        }
        let root = self.workspace_root.clone();
        let editor = self.editor.clone();
        let client = self.client.clone();
        cx.spawn(async move |_this, cx| {
            if let Ok(text) = client.read_file(&cx, &root, &path).await {
                let _ = editor.update(cx, |ed, cx| {
                    ed.open_file(path, text, cx);
                });
            }
        })
        .detach();
    }

    /// 执行常用命令动作（工具栏菜单、命令面板、全局搜索共用）。
    pub fn handle_action(&mut self, action_id: &str, cx: &mut Context<Self>) {
        // 主题子菜单：menu.theme.<id>，直接写设置并应用主题。
        if let Some(theme_id) = action_id.strip_prefix("menu.theme.") {
            let theme_id = theme_id.to_string();
            settings::update(cx, |s| {
                s.theme = theme_id.clone();
                s.sync_system_theme = false;
            });
            settings::apply_theme(&theme_id);
            let mode = if crate::theme::ThemePalette::is_light(&theme_id) {
                gpui_kit::component::ThemeMode::Light
            } else {
                gpui_kit::component::ThemeMode::Dark
            };
            gpui_kit::component::Theme::change(mode, None, cx);
            cx.notify();
            return;
        }
        match action_id {
            "workbench.new_file" | "file.new_file" | "file.new_tab" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.open_file("untitled.txt".to_string(), String::new(), cx);
                });
            }
            "workbench.save" | "file.save" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.save_active(cx);
                });
            }
            "workbench.close_tab" | "file.close_editor" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    if let Some(idx) = ed.active_tab_index {
                        ed.close_tab(idx, cx);
                    }
                });
            }
            "workbench.toggle_terminal" | "view.toggle_bottom_panel" => {
                let _ = self.bottom_panel.update(cx, |bp, cx| {
                    bp.toggle_collapsed(cx);
                });
            }
            "workbench.toggle_sidebar" | "view.toggle_sidebar" | "view.toggle_activity_rail" => {
                self.toggle_sidebar(cx);
            }
            "workbench.open_settings" | "tools.settings" => {
                self.open_settings(cx);
            }
            "workbench.refresh_workspace" => {
                let _ = self.sidebar.update(cx, |sb, cx| {
                    sb.refresh(cx);
                    sb.refresh_git(cx);
                });
            }
            "workbench.run" | "run.run" | "run.start" => {
                self.send_terminal_command("cargo check", cx);
            }
            "workbench.debug" | "run.debug" => {
                self.append_log("[Debug] Launching DAP debug session...", cx);
            }
            "workbench.clear_terminal" | "terminal.clear" => {
                let _ = self.bottom_panel.update(cx, |bp, cx| {
                    let _ = bp.terminal.update(cx, |term, cx| {
                        term.clear(cx);
                    });
                });
            }
            "view.quick_open" | "go.go_to_file" => {
                self.open_quick_open(cx);
            }
            "view.command_palette" => {
                self.open_command_palette(cx);
            }
            "view.toggle_status_bar" => {
                let current = settings::get(cx).show_status_bar;
                settings::update(cx, |s| s.show_status_bar = !current);
                cx.notify();
            }
            "view.welcome" => {
                self.show_welcome = !self.show_welcome;
                cx.notify();
            }
            "help.about" => {
                self.append_log(
                    "[About] Lithe IDE for Linux (Powered by GPUI Kit & Rust Core)",
                    cx,
                );
            }
            "file.exit" | "window.close" | "file.close_window" => {
                cx.quit();
            }
            "window.minimize" => {
                cx.defer(|cx| {
                    if let Some(handle) = cx.active_window() {
                        let _ = handle.update(cx, |_, window, _| window.minimize_window());
                    }
                });
            }
            "window.maximize" => {
                cx.defer(|cx| {
                    if let Some(handle) = cx.active_window() {
                        let _ = handle.update(cx, |_, window, _| window.zoom_window());
                    }
                });
            }
            // 全局搜索与查找：查找替换 UI 未做，复用全局搜索弹窗。
            "view.global_search" | "edit.find" | "edit.find_replace" => {
                self.open_search_everywhere(cx);
            }
            // 诊断信息：底部面板切换到 Diagnostics 并展开。
            "view.diagnostics" => {
                let _ = self.bottom_panel.update(cx, |bp, cx| {
                    bp.set_tab(BottomTab::Diagnostics, cx);
                });
            }
            // 显示资源管理器：侧边栏切到 Explorer 并展开。
            "view.show_explorer" => {
                self.sidebar_visible = true;
                let _ = self
                    .activity_rail
                    .update(cx, |r, cx| r.set_active_view(Some("files".to_string()), cx));
                let _ = self
                    .sidebar
                    .update(cx, |sb, cx| sb.set_tab(SidebarTab::Explorer, cx));
                cx.notify();
            }
            // 显示 Git 面板：侧边栏切到 Git 并展开。
            "view.show_git" => {
                self.sidebar_visible = true;
                let _ = self
                    .activity_rail
                    .update(cx, |r, cx| r.set_active_view(Some("git".to_string()), cx));
                let _ = self
                    .sidebar
                    .update(cx, |sb, cx| sb.set_tab(SidebarTab::Git, cx));
                cx.notify();
            }
            // GitHub / 运行调试面板尚未接入后端，仅占位提示。
            "view.show_github" => {
                self.append_log("[GitHub] GitHub panel is not wired yet.", cx);
            }
            "view.show_debug" => {
                self.append_log("[Run and Debug] Debug panel is not wired yet.", cx);
            }
            // 快捷键设置：设置对话框切到 Keyboard 分类并打开。
            "tools.shortcuts" | "help.shortcuts" => {
                let _ = self.settings_dialog.update(cx, |d, cx| {
                    d.set_category(SettingsCategory::Keyboard, cx);
                });
                self.open_settings(cx);
            }
            // ---- File：新窗口 / 文件夹 / 另存为 / 标签页批量操作 ----
            "file.new_window" => {
                if let Ok(exe) = std::env::current_exe() {
                    let _ = std::process::Command::new(exe).spawn();
                }
            }
            "file.open_folder" => {
                if let Some(dir) = ProjectDialog::pick_folder(None) {
                    self.open_project_path(dir, cx);
                }
            }
            "file.close_folder" => {
                self.show_welcome = true;
                cx.notify();
            }
            "file.save_as" => {
                self.save_active_as(cx);
            }
            "file.save_all" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.save_all_tabs(cx);
                });
            }
            "file.revert" => {
                self.revert_active_file(cx);
            }
            "file.close_all" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.close_all_tabs(cx);
                });
            }
            "file.close_others" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.close_other_tabs(cx);
                });
            }
            "file.close_saved" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.close_saved_tabs(cx);
                });
            }
            "file.close_left" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.close_tabs_to_left(cx);
                });
            }
            "file.close_right" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.close_tabs_to_right(cx);
                });
            }
            "file.reopen_closed" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.reopen_closed_tab(cx);
                });
            }
            // ---- Edit：撤销/剪贴板/行操作（需 window 的经 defer 下发） ----
            "edit.undo" => {
                self.editor_window_action(cx, |ed, window, cx| ed.undo(window, cx));
            }
            "edit.redo" => {
                self.editor_window_action(cx, |ed, window, cx| ed.redo(window, cx));
            }
            "edit.cut" => {
                self.editor_window_action(cx, |ed, window, cx| ed.cut(window, cx));
            }
            "edit.copy" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.copy(cx);
                });
            }
            "edit.paste" => {
                self.editor_window_action(cx, |ed, window, cx| ed.paste(window, cx));
            }
            "edit.select_all" => {
                self.editor_window_action(cx, |ed, window, cx| ed.select_all(window, cx));
            }
            "edit.toggle_comment" => {
                self.editor_window_action(cx, |ed, window, cx| ed.toggle_comment(window, cx));
            }
            "edit.duplicate_line" => {
                self.editor_window_action(cx, |ed, window, cx| ed.duplicate_line(window, cx));
            }
            "edit.delete_line" => {
                self.editor_window_action(cx, |ed, window, cx| ed.delete_line(window, cx));
            }
            "edit.move_up" => {
                self.editor_window_action(cx, |ed, window, cx| ed.move_line_up(window, cx));
            }
            "edit.move_down" => {
                self.editor_window_action(cx, |ed, window, cx| ed.move_line_down(window, cx));
            }
            // ---- Go：跳转到行 / 标签页切换 ----
            "go.go_to_line" => {
                self.open_go_to_line(cx);
            }
            "go.next_tab" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.goto_next_tab(cx);
                });
            }
            "go.prev_tab" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.goto_prev_tab(cx);
                });
            }
            // ---- View：显示开关 / 缩放 ----
            "view.toggle_wrap" => {
                self.editor_window_action(cx, |ed, window, cx| ed.toggle_wrap(window, cx));
            }
            "view.toggle_line_numbers" => {
                self.editor_window_action(cx, |ed, window, cx| ed.toggle_line_numbers(window, cx));
            }
            "view.toggle_whitespace" => {
                self.editor_window_action(cx, |ed, window, cx| ed.toggle_whitespace(window, cx));
            }
            "view.zoom_in" => {
                settings::update(cx, |s| s.font_size = (s.font_size + 1.0).min(22.0));
                let msg = format!(
                    "[View] Font size: {} px",
                    settings::get(cx).font_size as i32
                );
                self.append_log(&msg, cx);
                cx.notify();
            }
            "view.zoom_out" => {
                settings::update(cx, |s| s.font_size = (s.font_size - 1.0).max(10.0));
                let msg = format!(
                    "[View] Font size: {} px",
                    settings::get(cx).font_size as i32
                );
                self.append_log(&msg, cx);
                cx.notify();
            }
            "view.reset_zoom" => {
                settings::update(cx, |s| s.font_size = 14.0);
                self.append_log("[View] Font size reset to 14 px", cx);
                cx.notify();
            }
            // ---- Terminal：新建会话 / 关闭面板（只关不开） ----
            "terminal.new" => {
                let _ = self.bottom_panel.update(cx, |bp, cx| {
                    bp.set_tab(BottomTab::Terminal, cx);
                    let _ = bp.terminal.update(cx, |term, cx| {
                        term.respawn(cx);
                    });
                });
            }
            "terminal.close" => {
                if !self.bottom_panel.read(cx).is_collapsed {
                    let _ = self.bottom_panel.update(cx, |bp, cx| {
                        bp.toggle_collapsed(cx);
                    });
                }
            }
            // ---- Window：全屏（gpui-pre `Window::toggle_fullscreen`） ----
            "window.fullscreen" => {
                cx.defer(|cx| {
                    if let Some(handle) = cx.active_window() {
                        let _ = handle.update(cx, |_, window, _| window.toggle_fullscreen());
                    }
                });
            }
            // ---- Help：外部链接经 `xdg-open` 打开 ----
            "help.docs" => {
                Self::open_url("https://lithe.top/docs");
            }
            "help.changelog" => {
                Self::open_url("https://github.com/1lck/Lithe-IDEA/releases");
            }
            "help.report_bug" => {
                Self::open_url("https://github.com/1lck/Lithe-IDEA/issues/new?template=01-bug.yml");
            }
            "help.feature" => {
                Self::open_url(
                    "https://github.com/1lck/Lithe-IDEA/issues/new?template=02-feature.yml",
                );
            }
            _ => {}
        }
    }

    /// 打开指定文件：对接 `lithe-core` 的 `read_file` 并更新编辑器
    pub fn open_file(&mut self, relative_path: &str, cx: &mut Context<Self>) {
        let root = self.workspace_root.clone();
        let path = relative_path.to_string();
        let editor = self.editor.clone();
        let client = self.client.clone();

        cx.spawn(async move |_this, cx| {
            let task = client.read_file(&cx, &root, &path);

            match task.await {
                Ok(text) => {
                    let _ = editor.update(cx, |ed, cx| {
                        ed.open_file(path, text, cx);
                    });
                }
                Err(err) => {
                    let err_msg = format!("// 读取文件失败: {}\n// 错误信息: {}", path, err);
                    let _ = editor.update(cx, |ed, cx| {
                        ed.open_file(path, err_msg, cx);
                    });
                }
            }
        })
        .detach();
    }
}

/// 活动栏视图 id → 侧边栏标签。
fn sidebar_tab_for(view_id: &str) -> Option<SidebarTab> {
    match view_id {
        "files" => Some(SidebarTab::Explorer),
        "search" => Some(SidebarTab::Search),
        "git" => Some(SidebarTab::Git),
        _ => None,
    }
}

/// 活动栏底部项 id → 底部面板标签（对齐 Tauri `BottomPaneTab`）。
fn bottom_tab_for(pane_id: &str) -> Option<BottomTab> {
    match pane_id {
        "terminal" => Some(BottomTab::Terminal),
        "run" | "maven" => Some(BottomTab::Run),
        "diagnostics" => Some(BottomTab::Diagnostics),
        "gitLog" => Some(BottomTab::GitLog),
        _ => None,
    }
}

fn this_sync_files(this: &WorkbenchView, cx: &mut Context<WorkbenchView>) {
    let mut file_list = Vec::new();
    if let Some(root_node) = &this.sidebar.read(cx).root_node {
        WorkbenchView::collect_all_file_paths(root_node, &mut file_list);
    }
    // 已打开标签页路径同步给快速打开的置顶分组（对齐 Tauri `openBufferFiles`）。
    let open_files: Vec<String> = this
        .editor
        .read(cx)
        .tabs
        .iter()
        .map(|tab| tab.path.clone())
        .collect();
    if !file_list.is_empty() {
        let _ = this.search_everywhere.update(cx, |search, cx| {
            search.set_files(file_list.clone(), cx);
        });
        let _ = this.quick_open.update(cx, |qo, cx| {
            qo.set_files(file_list, cx);
        });
    }
    if !open_files.is_empty() {
        let _ = this.quick_open.update(cx, |qo, cx| {
            qo.set_open_files(open_files, cx);
        });
    }
}

impl Render for WorkbenchView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let show_status_bar = settings::get(cx).show_status_bar;

        // 通知诊断行点击的待跳转：文件加载完成后跳到指定行（1 起）。
        if let Some(line) = self.pending_goto_line.take() {
            let _ = self.editor.update(cx, |ed, cx| {
                ed.go_to_line(line, window, cx);
            });
        }
        // 右侧铃铛角标与通知未读数同步（变化时才 notify，避免渲染循环）。
        {
            let unread = self.notifications.read(cx).unread_count();
            let _ = self.plugin_rail.update(cx, |rail, cx| {
                rail.set_unread(unread, cx);
            });
        }

        div()
            .track_focus(&self.focus_handle)
            .relative()
            .size_full()
            .bg(ThemeColors::background())
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                let key = event.keystroke.key.as_str();
                let modifiers = event.keystroke.modifiers;

                // 浮层优先：Esc 关闭最上层模态。
                if key == "escape" {
                    if this.show_branch_manager {
                        this.show_branch_manager = false;
                    } else if this.show_command_palette {
                        this.show_command_palette = false;
                    } else if this.show_quick_open {
                        this.show_quick_open = false;
                    } else if this.show_go_to_line {
                        this.show_go_to_line = false;
                    } else if this.show_search_everywhere {
                        this.show_search_everywhere = false;
                    } else if this.show_settings_dialog {
                        this.show_settings_dialog = false;
                    }
                    cx.notify();
                    return;
                }

                if modifiers.control || modifiers.platform {
                    if modifiers.shift && key == "p" {
                        this.open_command_palette(cx);
                        return;
                    }
                    if modifiers.shift && key == "f" {
                        this.open_search_everywhere(cx);
                        return;
                    }
                    match key {
                        "p" => this.open_quick_open(cx),
                        "," => this.open_settings(cx),
                        "b" => this.toggle_sidebar(cx),
                        "`" => {
                            let _ = this.bottom_panel.update(cx, |bp, cx| {
                                bp.toggle_collapsed(cx);
                            });
                        }
                        "j" => {
                            let _ = this.bottom_panel.update(cx, |bp, cx| {
                                bp.set_tab(BottomTab::Terminal, cx);
                            });
                        }
                        // 行操作快捷键与菜单展示一致（上游编辑器不原生支持）。
                        // 按键监听自带 `window`，直接下发，避免经句柄二次
                        // `update` 的重入借用失败。
                        "d" => this.editor_direct(window, cx, |ed, window, cx| {
                            ed.duplicate_line(window, cx);
                        }),
                        "/" => this.editor_direct(window, cx, |ed, window, cx| {
                            ed.toggle_comment(window, cx);
                        }),
                        _ => {
                            if modifiers.shift && (key == "k" || key == "K") {
                                this.editor_direct(window, cx, |ed, window, cx| {
                                    ed.delete_line(window, cx);
                                });
                            }
                        }
                    }
                    // Alt+Up/Down 移动行（`modifiers.alt`）。
                    if modifiers.alt && (key == "up" || key == "down") {
                        if key == "up" {
                            this.editor_direct(window, cx, |ed, window, cx| {
                                ed.move_line_up(window, cx);
                            });
                        } else {
                            this.editor_direct(window, cx, |ed, window, cx| {
                                ed.move_line_down(window, cx);
                            });
                        }
                    }
                }
            }))
            .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _window, cx| {
                if this.is_resizing_sidebar {
                    let current_x = f32::from(event.position.x);
                    let delta = current_x - this.drag_start_x;
                    let new_width = (this.initial_resize_size + delta).clamp(160.0, 600.0);
                    if (this.sidebar_width - new_width).abs() > 0.5 {
                        this.sidebar_width = new_width;
                        cx.notify();
                    }
                } else if this.is_resizing_bottom_panel {
                    let current_y = f32::from(event.position.y);
                    let delta = this.drag_start_y - current_y;
                    let new_height = (this.initial_resize_size + delta).clamp(120.0, 500.0);
                    if (this.bottom_panel_height - new_height).abs() > 0.5 {
                        this.bottom_panel_height = new_height;
                        let _ = this.bottom_panel.update(cx, |bp, cx| {
                            bp.set_height(new_height, cx);
                        });
                        cx.notify();
                    }
                }
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _event: &MouseUpEvent, _window, cx| {
                    if this.is_resizing_sidebar {
                        this.is_resizing_sidebar = false;
                        let width = this.sidebar_width;
                        settings::update(cx, |s| s.sidebar_width = width);
                        cx.notify();
                    }
                    if this.is_resizing_bottom_panel {
                        this.is_resizing_bottom_panel = false;
                        cx.notify();
                    }
                }),
            )
            .child(if self.show_welcome {
                self.welcome_screen.clone().into_any_element()
            } else {
                self.render_workbench(show_status_bar, cx)
                    .into_any_element()
            })
            .when(self.show_search_everywhere, |view| {
                view.child(self.search_everywhere.clone())
            })
            .when(self.show_quick_open, |view| {
                view.child(self.quick_open.clone())
            })
            .when(self.show_go_to_line, |view| {
                view.child(self.go_to_line.clone())
            })
            .when(self.show_command_palette, |view| {
                view.child(self.command_palette.clone())
            })
            .when(self.show_settings_dialog, |view| {
                view.child(self.settings_dialog.clone())
            })
            .when(self.show_project_dialog, |view| {
                view.child(self.project_dialog.clone())
            })
            .when(self.show_branch_manager, |view| {
                view.child(self.branch_manager.clone())
            })
    }
}

impl WorkbenchView {
    /// 渲染工作台主体（顶栏 / 侧边栏 / 编辑区 / 底部面板 / 状态栏）。
    fn render_workbench(&self, show_status_bar: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let bottom_visible = self.bottom_panel.read(cx).is_visible();
        let bottom_splitter = self.render_bottom_splitter(cx);
        let right_width = settings::get(cx).right_tool_window_width;
        v_flex()
            .size_full()
            .bg(ThemeColors::background())
            .child(self.toolbar.clone())
            .child(
                // 主工作区：左活动栏 + 侧边栏 + 编辑区 + 右插件活动栏
                h_flex()
                    .flex_1()
                    .w_full()
                    .min_h_0()
                    .child(self.activity_rail.clone())
                    .when(self.sidebar_visible, |layout| {
                        layout
                            .child(
                                div()
                                    .w(px(self.sidebar_width))
                                    .h_full()
                                    .flex_shrink_0()
                                    .child(self.sidebar.clone()),
                            )
                            .child(self.render_sidebar_splitter(cx))
                    })
                    .child(
                        div()
                            .flex_1()
                            .h_full()
                            .min_w_0()
                            .bg(ThemeColors::background())
                            .child(self.editor.clone()),
                    )
                    .when_some(self.right_tool, |layout, tool| {
                        let panel = match tool {
                            RightToolView::Notifications => {
                                self.notifications.clone().into_any_element()
                            }
                            RightToolView::Maven => self.maven.clone().into_any_element(),
                            RightToolView::Extensions => self.extensions.clone().into_any_element(),
                        };
                        layout.child(
                            div()
                                .w(px(right_width))
                                .h_full()
                                .flex_shrink_0()
                                .border_l_1()
                                .border_color(ThemeColors::border())
                                .child(panel),
                        )
                    })
                    .child(self.plugin_rail.clone()),
            )
            .when(bottom_visible, |layout| layout.child(bottom_splitter))
            .when(bottom_visible, |layout| {
                layout.child(self.bottom_panel.clone())
            })
            .when(show_status_bar, |layout| {
                layout.child(self.status_bar.clone())
            })
    }

    fn render_sidebar_splitter(&self, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .id("sidebar-splitter")
            .w(px(4.0))
            .h_full()
            .cursor_col_resize()
            .bg(if self.is_resizing_sidebar {
                ThemeColors::primary()
            } else {
                ThemeColors::border()
            })
            .hover(|h| h.bg(ThemeColors::primary()))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, _window, cx| {
                    this.is_resizing_sidebar = true;
                    this.drag_start_x = f32::from(event.position.x);
                    this.initial_resize_size = this.sidebar_width;
                    cx.notify();
                }),
            )
    }

    fn render_bottom_splitter(&self, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .id("bottom-panel-splitter")
            .h(px(4.0))
            .w_full()
            .cursor_row_resize()
            .bg(if self.is_resizing_bottom_panel {
                ThemeColors::primary()
            } else {
                ThemeColors::border()
            })
            .hover(|h| h.bg(ThemeColors::primary()))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, _window, cx| {
                    this.is_resizing_bottom_panel = true;
                    this.drag_start_y = f32::from(event.position.y);
                    this.initial_resize_size = this.bottom_panel_height;
                    cx.notify();
                }),
            )
    }
}
