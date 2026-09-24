use gpui_kit::component::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, FocusHandle, InteractiveElement as _, IntoElement,
    KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, ParentElement as _,
    Render, Styled as _, Subscription, Window,
};

use crate::core::CoreClient;
use crate::theme::ThemeColors;
use crate::workbench::activity_rail::{ActivityRailEvent, ActivityRailView, ActivityTab};
use crate::workbench::bottom_panel::BottomPanelView;
use crate::workbench::editor::EditorView;
use crate::workbench::search_everywhere::{
    SearchEverywhereEvent, SearchEverywhereModal,
};
use crate::workbench::settings_dialog::{SettingsDialog, SettingsEvent};
use crate::workbench::sidebar::{FileEntry, SidebarEvent, SidebarTab, SidebarView};
use crate::workbench::status_bar::StatusBarView;
use crate::workbench::toolbar::{ToolbarEvent, ToolbarView};

/// Linux 前端主工作台视图组件（复刻 macOS LitheTheme / IntelliJ 架构）
pub struct WorkbenchView {
    /// 项目工作区根路径
    pub workspace_root: String,
    /// 侧边栏是否展开
    pub sidebar_visible: bool,
    /// 侧边栏宽度（默认 260.0，支持拖拽调节）
    pub sidebar_width: f32,
    /// 底部面板高度（默认 240.0，支持拖拽调节）
    pub bottom_panel_height: f32,
    /// 是否正在调节侧边栏宽度
    pub is_resizing_sidebar: bool,
    /// 是否正在调节底部面板高度
    pub is_resizing_bottom_panel: bool,
    drag_start_x: f32,
    drag_start_y: f32,
    initial_resize_size: f32,

    /// 全局搜索弹窗浮层是否可见
    pub show_search_everywhere: bool,
    /// 设置模态对话框是否可见
    pub show_settings_dialog: bool,

    /// 顶部标题栏/工具栏
    pub toolbar: Entity<ToolbarView>,
    /// 左侧垂直活动栏 (Activity Rail)
    pub activity_rail: Entity<ActivityRailView>,
    /// 侧边栏面板 (Files / Git / Search)
    pub sidebar: Entity<SidebarView>,
    /// 主代码编辑器区
    pub editor: Entity<EditorView>,
    /// 底部抽屉面板 (Terminal / Output / Problems)
    pub bottom_panel: Entity<BottomPanelView>,
    /// 底部状态栏 (Status Bar)
    pub status_bar: Entity<StatusBarView>,
    /// 全局搜索弹窗
    pub search_everywhere: Entity<SearchEverywhereModal>,
    /// 设置模态对话框
    pub settings_dialog: Entity<SettingsDialog>,

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

    pub fn with_root(
        workspace_root: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let root = workspace_root.clone();

        let toolbar = cx.new(|_cx| ToolbarView::new(&root));
        let activity_rail = cx.new(|_cx| ActivityRailView::new());
        let sidebar = cx.new(|cx| SidebarView::new(root.clone(), cx));
        let editor = cx.new(|cx| EditorView::new(root.clone(), window, cx));
        let bottom_panel = cx.new(|cx| BottomPanelView::new(root.clone(), cx));
        let status_bar = cx.new(|_cx| StatusBarView::new());
        let search_everywhere = cx.new(|cx| SearchEverywhereModal::new(cx));
        let settings_dialog = cx.new(|_cx| SettingsDialog::new());
        let focus_handle = cx.focus_handle();

        // 1. 订阅侧边栏事件（打开文件、新建文件、提交 Git）
        let status_bar_clone = status_bar.clone();
        let bottom_panel_sidebar = bottom_panel.clone();
        let sub_sidebar = cx.subscribe(&sidebar, move |this, sidebar, event: &SidebarEvent, cx| {
            match event {
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
            }
        });

        // 2. 观察侧边栏状态变化（分支同步与工作区文件快照同步给全局搜索）
        let toolbar_branch_sync = toolbar.clone();
        let status_bar_branch_sync = status_bar.clone();
        let search_sync = search_everywhere.clone();
        let obs_sidebar = cx.observe(&sidebar, move |_this, sidebar, cx| {
            let branch = sidebar.read(cx).git_branch.clone();
            let _ = toolbar_branch_sync.update(cx, |tb, cx| {
                tb.set_git_branch(branch.clone(), cx);
            });
            let _ = status_bar_branch_sync.update(cx, |sb, cx| {
                sb.set_git_branch(branch, cx);
            });

            // 收集所有文件供全局搜索
            let mut file_list = Vec::new();
            if let Some(root_node) = &sidebar.read(cx).root_node {
                Self::collect_all_file_paths(root_node, &mut file_list);
            }
            if !file_list.is_empty() {
                let _ = search_sync.update(cx, |search, cx| {
                    search.set_files(file_list, cx);
                });
            }
        });

        // 3. 订阅左侧活动栏 (Activity Rail) 事件
        let sidebar_clone = sidebar.clone();
        let bottom_panel_clone = bottom_panel.clone();
        let sub_rail = cx.subscribe(&activity_rail, move |this, rail, event: &ActivityRailEvent, cx| {
            match event {
                ActivityRailEvent::SelectTab(tab) => {
                    let sb_tab = match tab {
                        ActivityTab::Explorer => SidebarTab::Explorer,
                        ActivityTab::Git => SidebarTab::Git,
                        ActivityTab::Search => SidebarTab::Search,
                    };

                    let was_active = this.sidebar_visible
                        && rail.read(cx).active_tab == Some(*tab);

                    if was_active {
                        this.sidebar_visible = false;
                        let _ = rail.update(cx, |r, cx| r.set_active_tab(None, cx));
                    } else {
                        this.sidebar_visible = true;
                        let _ = rail.update(cx, |r, cx| r.set_active_tab(Some(*tab), cx));
                        let _ = sidebar_clone.update(cx, |sb, cx| sb.set_tab(sb_tab, cx));
                    }
                    cx.notify();
                }
                ActivityRailEvent::ToggleTerminal => {
                    let _ = bottom_panel_clone.update(cx, |bp, cx| {
                        bp.toggle_collapsed(cx);
                    });
                }
                ActivityRailEvent::OpenSettings => {
                    this.show_settings_dialog = true;
                    cx.notify();
                }
            }
        });

        // 4. 订阅顶部工具栏事件
        let sub_toolbar = cx.subscribe(&toolbar, |this, _toolbar, event: &ToolbarEvent, cx| {
            match event {
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
                    this.sidebar_visible = !this.sidebar_visible;
                    let tab = if this.sidebar_visible {
                        Some(ActivityTab::Explorer)
                    } else {
                        None
                    };
                    let _ = this.activity_rail.update(cx, |r, cx| r.set_active_tab(tab, cx));
                    cx.notify();
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
                    this.open_search_everywhere(cx);
                }
                ToolbarEvent::Run => {
                    let _ = this.bottom_panel.update(cx, |bp, cx| {
                        bp.append_log("[Run] Executing default run configuration...".to_string(), cx);
                        let _ = bp.terminal.update(cx, |term, cx| {
                            term.send_command("echo '[Lithe Run]' && cargo check", cx);
                        });
                    });
                }
                ToolbarEvent::Debug => {
                    let _ = this.bottom_panel.update(cx, |bp, cx| {
                        bp.append_log("[Debug] Launching DAP debug session...".to_string(), cx);
                    });
                }
                ToolbarEvent::Stop => {
                    let _ = this.bottom_panel.update(cx, |bp, cx| {
                        bp.append_log("[Stop] Session terminated by user.".to_string(), cx);
                    });
                }
                ToolbarEvent::OpenSettings => {
                    this.show_settings_dialog = true;
                    cx.notify();
                }
                ToolbarEvent::About => {
                    let _ = this.bottom_panel.update(cx, |bp, cx| {
                        bp.append_log("[About] Lithe IDE for Linux (Powered by GPUI Kit & Rust Core)".to_string(), cx);
                    });
                }
                ToolbarEvent::Exit => {
                    cx.quit();
                }
            }
        });

        // 5. 订阅全局搜索事件 (SearchEverywhereEvent)
        let status_bar_search = status_bar.clone();
        let sub_search = cx.subscribe(&search_everywhere, move |this, _search, event: &SearchEverywhereEvent, cx| {
            match event {
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
            }
        });

        // 6. 订阅设置对话框事件 (SettingsEvent)
        let sub_settings = cx.subscribe(&settings_dialog, |this, _dialog, event: &SettingsEvent, cx| {
            match event {
                SettingsEvent::Close => {
                    this.show_settings_dialog = false;
                    cx.notify();
                }
            }
        });

        Self {
            workspace_root,
            sidebar_visible: true,
            sidebar_width: 260.0,
            bottom_panel_height: 240.0,
            is_resizing_sidebar: false,
            is_resizing_bottom_panel: false,
            drag_start_x: 0.0,
            drag_start_y: 0.0,
            initial_resize_size: 0.0,
            show_search_everywhere: false,
            show_settings_dialog: false,
            toolbar,
            activity_rail,
            sidebar,
            editor,
            bottom_panel,
            status_bar,
            search_everywhere,
            settings_dialog,
            focus_handle,
            client: CoreClient::new(),
            _subscriptions: vec![
                sub_sidebar,
                obs_sidebar,
                sub_rail,
                sub_toolbar,
                sub_search,
                sub_settings,
            ],
        }
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

    /// 执行常用命令动作
    pub fn handle_action(&mut self, action_id: &str, cx: &mut Context<Self>) {
        match action_id {
            "workbench.new_file" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.open_file("untitled.txt".to_string(), String::new(), cx);
                });
            }
            "workbench.save" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    ed.save_active(cx);
                });
            }
            "workbench.close_tab" => {
                let _ = self.editor.update(cx, |ed, cx| {
                    if let Some(idx) = ed.active_tab_index {
                        ed.close_tab(idx, cx);
                    }
                });
            }
            "workbench.toggle_terminal" => {
                let _ = self.bottom_panel.update(cx, |bp, cx| {
                    bp.toggle_collapsed(cx);
                });
            }
            "workbench.toggle_sidebar" => {
                self.sidebar_visible = !self.sidebar_visible;
                let tab = if self.sidebar_visible {
                    Some(ActivityTab::Explorer)
                } else {
                    None
                };
                let _ = self.activity_rail.update(cx, |r, cx| r.set_active_tab(tab, cx));
                cx.notify();
            }
            "workbench.open_settings" => {
                self.show_settings_dialog = true;
                cx.notify();
            }
            "workbench.refresh_workspace" => {
                let _ = self.sidebar.update(cx, |sb, cx| {
                    sb.refresh(cx);
                    sb.refresh_git(cx);
                });
            }
            "workbench.run" => {
                let _ = self.bottom_panel.update(cx, |bp, cx| {
                    bp.append_log("[Run] Executing default run configuration...".to_string(), cx);
                    let _ = bp.terminal.update(cx, |term, cx| {
                        term.send_command("cargo check", cx);
                    });
                });
            }
            "workbench.debug" => {
                let _ = self.bottom_panel.update(cx, |bp, cx| {
                    bp.append_log("[Debug] Launching DAP debug session...".to_string(), cx);
                });
            }
            "workbench.clear_terminal" => {
                let _ = self.bottom_panel.update(cx, |bp, cx| {
                    let _ = bp.terminal.update(cx, |term, cx| {
                        term.clear(cx);
                    });
                });
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

fn this_sync_files(this: &WorkbenchView, cx: &mut Context<WorkbenchView>) {
    let mut file_list = Vec::new();
    if let Some(root_node) = &this.sidebar.read(cx).root_node {
        WorkbenchView::collect_all_file_paths(root_node, &mut file_list);
    }
    if !file_list.is_empty() {
        let _ = this.search_everywhere.update(cx, |search, cx| {
            search.set_files(file_list, cx);
        });
    }
}

impl Render for WorkbenchView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .track_focus(&self.focus_handle)
            .relative()
            .size_full()
            .bg(ThemeColors::bg_editor())
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                let key = event.keystroke.key.as_str();
                // 键盘快捷键监听
                if event.keystroke.modifiers.control || event.keystroke.modifiers.platform {
                    match key {
                        "p" => {
                            this.open_search_everywhere(cx);
                        }
                        "," => {
                            this.show_settings_dialog = true;
                            cx.notify();
                        }
                        "b" => {
                            this.sidebar_visible = !this.sidebar_visible;
                            let tab = if this.sidebar_visible {
                                Some(ActivityTab::Explorer)
                            } else {
                                None
                            };
                            let _ = this.activity_rail.update(cx, |r, cx| r.set_active_tab(tab, cx));
                            cx.notify();
                        }
                        "`" => {
                            let _ = this.bottom_panel.update(cx, |bp, cx| {
                                bp.toggle_collapsed(cx);
                            });
                        }
                        _ => {}
                    }
                } else if key == "escape" {
                    if this.show_search_everywhere {
                        this.show_search_everywhere = false;
                        cx.notify();
                    } else if this.show_settings_dialog {
                        this.show_settings_dialog = false;
                        cx.notify();
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
                    if this.is_resizing_sidebar || this.is_resizing_bottom_panel {
                        this.is_resizing_sidebar = false;
                        this.is_resizing_bottom_panel = false;
                        cx.notify();
                    }
                }),
            )
            .child(
                v_flex()
                    .size_full()
                    .bg(ThemeColors::bg_editor())
                    .child(
                        // 1. 顶部标题栏/工具栏 (Toolbar)
                        self.toolbar.clone(),
                    )
                    .child(
                        // 2. 主工作区区域（ActivityRail + 侧边栏 + 可调节垂直Splitter + 编辑器主岛）
                        h_flex()
                            .flex_1()
                            .w_full()
                            .child(
                                // 左侧垂直图标活动栏 (Activity Rail)
                                self.activity_rail.clone(),
                            )
                            .when(self.sidebar_visible, |layout| {
                                layout
                                    .child(
                                        // 侧边栏内容面板 (Explorer / Search / Git)
                                        div()
                                            .w(px(self.sidebar_width))
                                            .h_full()
                                            .flex_shrink_0()
                                            .child(self.sidebar.clone()),
                                    )
                                    .child(
                                        // 侧边栏与主编辑器之间的精致 Splitter 分隔条
                                        div()
                                            .id("sidebar-splitter")
                                            .w(px(4.0))
                                            .h_full()
                                            .cursor_col_resize()
                                            .bg(if self.is_resizing_sidebar {
                                                ThemeColors::accent_blue()
                                            } else {
                                                ThemeColors::border()
                                            })
                                            .hover(|h| h.bg(ThemeColors::accent_blue()))
                                            .on_mouse_down(
                                                MouseButton::Left,
                                                cx.listener(|this, event: &MouseDownEvent, _window, cx| {
                                                    this.is_resizing_sidebar = true;
                                                    this.drag_start_x = f32::from(event.position.x);
                                                    this.initial_resize_size = this.sidebar_width;
                                                    cx.notify();
                                                }),
                                            ),
                                    )
                            })
                            .child(
                                // 中央编辑器主岛
                                div()
                                    .flex_1()
                                    .h_full()
                                    .bg(ThemeColors::bg_editor())
                                    .child(self.editor.clone()),
                            ),
                    )
                    .child(
                        // 主编辑器与底栏之间的精致 Splitter 分隔条
                        div()
                            .id("bottom-panel-splitter")
                            .h(px(4.0))
                            .w_full()
                            .cursor_row_resize()
                            .bg(if self.is_resizing_bottom_panel {
                                ThemeColors::accent_blue()
                            } else {
                                ThemeColors::border()
                            })
                            .hover(|h| h.bg(ThemeColors::accent_blue()))
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(|this, event: &MouseDownEvent, _window, cx| {
                                    this.is_resizing_bottom_panel = true;
                                    this.drag_start_y = f32::from(event.position.y);
                                    this.initial_resize_size = this.bottom_panel_height;
                                    cx.notify();
                                }),
                            ),
                    )
                    .child(
                        // 3. 底部抽屉面板 (Terminal / Output / Problems)
                        self.bottom_panel.clone(),
                    )
                    .child(
                        // 4. 最底部状态栏 (Status Bar)
                        self.status_bar.clone(),
                    ),
            )
            .when(self.show_search_everywhere, |view| {
                view.child(self.search_everywhere.clone())
            })
            .when(self.show_settings_dialog, |view| {
                view.child(self.settings_dialog.clone())
            })
    }
}
