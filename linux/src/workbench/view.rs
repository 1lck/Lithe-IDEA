use gpui_kit::component::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, IntoElement, ParentElement as _, Render,
    Styled as _, Subscription, Window,
};

use crate::core::CoreClient;
use crate::theme::ThemeColors;
use crate::workbench::activity_rail::{ActivityRailEvent, ActivityRailView, ActivityTab};
use crate::workbench::bottom_panel::BottomPanelView;
use crate::workbench::editor::EditorView;
use crate::workbench::sidebar::{SidebarEvent, SidebarTab, SidebarView};
use crate::workbench::status_bar::StatusBarView;
use crate::workbench::toolbar::{ToolbarEvent, ToolbarView};

/// Linux 前端主工作台视图组件（复刻 macOS LitheTheme / Tauri 架构）
pub struct WorkbenchView {
    /// 项目工作区根路径
    pub workspace_root: String,
    /// 侧边栏是否展开
    pub sidebar_visible: bool,
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
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let root = workspace_root.clone();

        let toolbar = cx.new(|_cx| ToolbarView::new(&root));
        let activity_rail = cx.new(|_cx| ActivityRailView::new());
        let sidebar = cx.new(|cx| SidebarView::new(root.clone(), cx));
        let editor = cx.new(|cx| EditorView::new(root.clone(), cx));
        let bottom_panel = cx.new(|cx| BottomPanelView::new(root.clone(), cx));
        let status_bar = cx.new(|_cx| StatusBarView::new());

        // 1. 订阅侧边栏文件打开事件
        let status_bar_clone = status_bar.clone();
        let sub_sidebar = cx.subscribe(&sidebar, move |this, _sidebar, event: &SidebarEvent, cx| {
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
            }
        });

        // 2. 观察侧边栏 Git 分支状态变化并同步至 Toolbar 与 StatusBar
        let toolbar_branch_sync = toolbar.clone();
        let status_bar_branch_sync = status_bar.clone();
        let obs_sidebar = cx.observe(&sidebar, move |_this, sidebar, cx| {
            let branch = sidebar.read(cx).git_branch.clone();
            let _ = toolbar_branch_sync.update(cx, |tb, cx| {
                tb.set_git_branch(branch.clone(), cx);
            });
            let _ = status_bar_branch_sync.update(cx, |sb, cx| {
                sb.set_git_branch(branch, cx);
            });
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
                    let _ = bottom_panel_clone.update(cx, |bp, cx| {
                        bp.append_log("[Settings] Settings dialog requested".to_string(), cx);
                    });
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
                    let _ = this.sidebar.update(cx, |sb, cx| {
                        sb.set_tab(SidebarTab::Search, cx);
                    });
                    this.sidebar_visible = true;
                    let _ = this.activity_rail.update(cx, |r, cx| {
                        r.set_active_tab(Some(ActivityTab::Search), cx)
                    });
                    cx.notify();
                }
                ToolbarEvent::Run => {
                    let _ = this.bottom_panel.update(cx, |bp, cx| {
                        bp.append_log("[Run] Executing default run configuration...".to_string(), cx);
                        let _ = bp.terminal.update(cx, |term, cx| {
                            term.send_command("echo '[Lithe Run]' && ls -la", cx);
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
                    let _ = this.bottom_panel.update(cx, |bp, cx| {
                        bp.append_log("[Settings] Settings dialog requested".to_string(), cx);
                    });
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

        Self {
            workspace_root,
            sidebar_visible: true,
            toolbar,
            activity_rail,
            sidebar,
            editor,
            bottom_panel,
            status_bar,
            client: CoreClient::new(),
            _subscriptions: vec![sub_sidebar, obs_sidebar, sub_rail, sub_toolbar],
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

impl Render for WorkbenchView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .bg(ThemeColors::bg_editor())
            .child(
                // 1. 顶部标题栏/工具栏 (Toolbar)
                self.toolbar.clone(),
            )
            .child(
                // 2. 主工作区区域（ActivityRail + 侧边栏 + 编辑器主岛）
                h_flex()
                    .flex_1()
                    .w_full()
                    .child(
                        // 左侧垂直图标活动栏 (Activity Rail)
                        self.activity_rail.clone(),
                    )
                    .when(self.sidebar_visible, |layout| {
                        layout.child(
                            // 侧边栏内容面板 (Explorer / Search / Git)
                            div()
                                .w(px(260.0))
                                .h_full()
                                .flex_shrink_0()
                                .child(self.sidebar.clone()),
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
                // 3. 底部抽屉面板 (Terminal / Output / Problems)
                self.bottom_panel.clone(),
            )
            .child(
                // 4. 最底部状态栏 (Status Bar)
                self.status_bar.clone(),
            )
    }
}
