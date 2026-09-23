use gpui_kit::component::{h_flex, v_flex, ActiveTheme as _};
use gpui_kit::{
    div, px, rgb, AppContext as _, Context, Entity, IntoElement, ParentElement as _, Render,
    Styled as _, Subscription, Window,
};

use crate::core::CoreClient;
use crate::workbench::bottom_panel::BottomPanelView;
use crate::workbench::editor::EditorView;
use crate::workbench::sidebar::{SidebarEvent, SidebarView};
use crate::workbench::toolbar::{ToolbarEvent, ToolbarView};

/// Linux 前端主工作台视图组件
pub struct WorkbenchView {
    /// 项目工作区根路径
    pub workspace_root: String,
    /// 顶部工具栏
    pub toolbar: Entity<ToolbarView>,
    /// 侧边栏视图实体
    pub sidebar: Entity<SidebarView>,
    /// 编辑器视图实体
    pub editor: Entity<EditorView>,
    /// 底部面板视图实体
    pub bottom_panel: Entity<BottomPanelView>,
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
        let root_for_toolbar = workspace_root.clone();
        let root_for_sidebar = workspace_root.clone();
        let root_for_editor = workspace_root.clone();
        let root_for_bottom = workspace_root.clone();

        let toolbar = cx.new(|_cx| ToolbarView::new(&root_for_toolbar));
        let sidebar = cx.new(|cx| SidebarView::new(root_for_sidebar, cx));
        let editor = cx.new(|cx| EditorView::new(root_for_editor, cx));
        let bottom_panel = cx.new(|cx| BottomPanelView::new(root_for_bottom, cx));

        // 1. 订阅侧边栏事件：点击文件打开
        let sub_sidebar = cx.subscribe(&sidebar, |this, _sidebar, event: &SidebarEvent, cx| {
            match event {
                SidebarEvent::OpenFile(path) => {
                    this.open_file(path, cx);
                }
            }
        });

        // 2. 订阅工具栏事件：保存、运行、终端切换
        let sub_toolbar = cx.subscribe(&toolbar, |this, _toolbar, event: &ToolbarEvent, cx| {
            match event {
                ToolbarEvent::Save => {
                    let _ = this.editor.update(cx, |ed, cx| {
                        ed.save_active(cx);
                    });
                }
                ToolbarEvent::ToggleTerminal => {
                    let _ = this.bottom_panel.update(cx, |bp, cx| {
                        bp.toggle_collapsed(cx);
                    });
                }
                ToolbarEvent::Run => {
                    let _ = this.bottom_panel.update(cx, |bp, cx| {
                        bp.append_log("[Run] Executing run configuration...".to_string(), cx);
                        let _ = bp.terminal.update(cx, |term, cx| {
                            term.send_command("echo '[Lithe Run]' && ls -la", cx);
                        });
                    });
                }
            }
        });

        Self {
            workspace_root,
            toolbar,
            sidebar,
            editor,
            bottom_panel,
            client: CoreClient::new(),
            _subscriptions: vec![sub_sidebar, sub_toolbar],
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
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .bg(cx.theme().background)
            .child(
                // 1. 顶部工具栏
                self.toolbar.clone(),
            )
            .child(
                // 2. 主体区域（左右布局）
                h_flex()
                    .flex_1()
                    .w_full()
                    .child(
                        // 左侧分栏：侧边栏（Explorer / Search / Git）
                        div()
                            .w(px(280.0))
                            .h_full()
                            .flex_shrink_0()
                            .border_r_1()
                            .border_color(rgb(0x23263b))
                            .child(self.sidebar.clone()),
                    )
                    .child(
                        // 右侧分栏：多标签代码编辑器
                        div()
                            .flex_1()
                            .h_full()
                            .child(self.editor.clone()),
                    ),
            )
            .child(
                // 3. 底部面板（终端 / 日志 / 问题）
                self.bottom_panel.clone(),
            )
    }
}
