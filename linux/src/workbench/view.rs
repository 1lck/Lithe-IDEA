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
use crate::workbench::command_palette::{CommandPaletteEvent, CommandPaletteModal};
use crate::workbench::editor::EditorView;
use crate::workbench::quick_open::{QuickOpenEvent, QuickOpenModal};
use crate::workbench::search_everywhere::{SearchEverywhereEvent, SearchEverywhereModal};
use crate::workbench::settings_dialog::{SettingsCategory, SettingsDialog, SettingsEvent};
use crate::workbench::sidebar::{FileEntry, SidebarEvent, SidebarTab, SidebarView};
use crate::workbench::status_bar::{StatusBarEvent, StatusBarView};
use crate::workbench::toolbar::{ToolbarEvent, ToolbarView};
use crate::workbench::welcome_screen::{WelcomeEvent, WelcomeScreenView};

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
    /// 命令面板浮层是否可见
    pub show_command_palette: bool,
    /// 设置模态对话框是否可见
    pub show_settings_dialog: bool,

    /// 顶部标题栏/工具栏
    pub toolbar: Entity<ToolbarView>,
    /// 左侧垂直活动栏 (Activity Rail)
    pub activity_rail: Entity<ActivityRailView>,
    /// 右侧插件活动栏 (Extensions / Notifications / Maven)
    pub plugin_rail: Entity<PluginActivityRailView>,
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
    /// 命令面板
    pub command_palette: Entity<CommandPaletteModal>,
    /// 设置模态对话框
    pub settings_dialog: Entity<SettingsDialog>,
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
        let command_palette = cx.new(|cx| CommandPaletteModal::new(cx));
        let settings_dialog = cx.new(|cx| SettingsDialog::new(cx));
        let welcome_screen = cx.new(|cx| WelcomeScreenView::new(cx));
        let focus_handle = cx.focus_handle();

        // 1. 订阅侧边栏事件（打开文件、新建文件、提交 Git）
        let status_bar_clone = status_bar.clone();
        let bottom_panel_sidebar = bottom_panel.clone();
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
                        let log_msg = format!("[Git Commit] {}", msg);
                        let _ = bottom_panel_sidebar.update(cx, |bp, cx| {
                            bp.append_log(log_msg.clone(), cx);
                            let _ = bp.terminal.update(cx, |term, cx| {
                                term.send_command(&format!("git commit -m \"{}\"", msg), cx);
                            });
                        });
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
        let obs_sidebar = cx.observe(&sidebar, move |_this, sidebar, cx| {
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
                    this.append_log("[Extensions] Opening extensions marketplace...", cx);
                    cx.notify();
                }
                PluginRailEvent::ToggleNotifications => {
                    this.append_log("[Notifications] Toggling notifications tool window...", cx);
                    cx.notify();
                }
                PluginRailEvent::ToggleMaven => {
                    let _ = this
                        .bottom_panel
                        .update(cx, |bp, cx| bp.set_tab(BottomTab::Terminal, cx));
                    this.append_log("[Maven] Opening Maven tool window...", cx);
                    cx.notify();
                }
            },
        );

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
                        this.append_log("[Run] Executing default run configuration...", cx);
                        let _ = this.bottom_panel.update(cx, |bp, cx| {
                            let _ = bp.terminal.update(cx, |term, cx| {
                                term.send_command("echo '[Lithe Run]' && cargo check", cx);
                            });
                        });
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
                    ToolbarEvent::NewProject
                    | ToolbarEvent::OpenProject
                    | ToolbarEvent::CloneRepository => {
                        this.append_log(
                            "[Project] Project picker is not wired to the backend yet.",
                            cx,
                        );
                    }
                    ToolbarEvent::OpenRecent => {
                        this.show_welcome = true;
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
                    this.show_quick_open = false;
                    cx.notify();
                }
                QuickOpenEvent::Close => {
                    this.show_quick_open = false;
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

        // 10. 订阅欢迎页事件
        let sub_welcome = cx.subscribe(
            &welcome_screen,
            |this, _welcome, event: &WelcomeEvent, cx| match event {
                WelcomeEvent::OpenFolder | WelcomeEvent::NewProject => {
                    this.append_log(
                        "[Welcome] Project picker is not wired to the backend yet.",
                        cx,
                    );
                }
                WelcomeEvent::CloneRepository => {
                    this.append_log(
                        "[Welcome] Clone repository is not wired to the backend yet.",
                        cx,
                    );
                }
                WelcomeEvent::OpenProject(path) => {
                    this.workspace_root = path.clone();
                    this.show_welcome = false;
                    let _ = this.sidebar.update(cx, |sb, cx| {
                        sb.root_path = path.clone();
                        sb.refresh(cx);
                        sb.refresh_git(cx);
                    });
                    cx.notify();
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
            show_command_palette: false,
            show_settings_dialog: false,
            toolbar,
            activity_rail,
            plugin_rail,
            sidebar,
            editor,
            bottom_panel,
            status_bar,
            search_everywhere,
            quick_open,
            command_palette,
            settings_dialog,
            welcome_screen,
            focus_handle,
            client: CoreClient::new(),
            _subscriptions: vec![
                sub_sidebar,
                obs_sidebar,
                sub_rail,
                sub_plugin_rail,
                sub_toolbar,
                sub_search,
                sub_quick_open,
                sub_command_palette,
                sub_settings,
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
            "workbench.toggle_terminal" | "view.toggle_bottom_panel" | "terminal.new" => {
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
            "workbench.run" | "run.run" => {
                self.append_log("[Run] Executing default run configuration...", cx);
                let _ = self.bottom_panel.update(cx, |bp, cx| {
                    let _ = bp.terminal.update(cx, |term, cx| {
                        term.send_command("cargo check", cx);
                    });
                });
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
            "file.exit" | "window.close" => {
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
            "tools.shortcuts" => {
                let _ = self.settings_dialog.update(cx, |d, cx| {
                    d.set_category(SettingsCategory::Keyboard, cx);
                });
                self.open_settings(cx);
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

/// 活动栏底部项 id → 底部面板标签。Linux 目前只有 Terminal / Diagnostics
/// 两种真实面板：run/maven/gitLog 暂落到 Terminal，待各自后端面板接入。
fn bottom_tab_for(pane_id: &str) -> Option<BottomTab> {
    match pane_id {
        "terminal" | "run" | "maven" | "gitLog" => Some(BottomTab::Terminal),
        "diagnostics" => Some(BottomTab::Diagnostics),
        _ => None,
    }
}

fn this_sync_files(this: &WorkbenchView, cx: &mut Context<WorkbenchView>) {
    let mut file_list = Vec::new();
    if let Some(root_node) = &this.sidebar.read(cx).root_node {
        WorkbenchView::collect_all_file_paths(root_node, &mut file_list);
    }
    if !file_list.is_empty() {
        let _ = this.search_everywhere.update(cx, |search, cx| {
            search.set_files(file_list.clone(), cx);
        });
        let _ = this.quick_open.update(cx, |qo, cx| {
            qo.set_files(file_list, cx);
        });
    }
}

impl Render for WorkbenchView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let show_status_bar = settings::get(cx).show_status_bar;

        div()
            .track_focus(&self.focus_handle)
            .relative()
            .size_full()
            .bg(ThemeColors::background())
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                let key = event.keystroke.key.as_str();
                let modifiers = event.keystroke.modifiers;

                // 浮层优先：Esc 关闭最上层模态。
                if key == "escape" {
                    if this.show_command_palette {
                        this.show_command_palette = false;
                    } else if this.show_quick_open {
                        this.show_quick_open = false;
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
                        _ => {}
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
            .when(self.show_command_palette, |view| {
                view.child(self.command_palette.clone())
            })
            .when(self.show_settings_dialog, |view| {
                view.child(self.settings_dialog.clone())
            })
    }
}

impl WorkbenchView {
    /// 渲染工作台主体（顶栏 / 侧边栏 / 编辑区 / 底部面板 / 状态栏）。
    fn render_workbench(&self, show_status_bar: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let bottom_visible = self.bottom_panel.read(cx).is_visible();
        let bottom_splitter = self.render_bottom_splitter(cx);
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
