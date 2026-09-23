use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgb, Context, InteractiveElement as _, IntoElement, ParentElement as _,
    Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::core::CoreClient;

#[derive(Debug, Clone)]
pub struct EditorTab {
    pub path: String,
    pub title: String,
    pub content: String,
    pub is_dirty: bool,
    pub cursor_line: usize,
    pub cursor_col: usize,
}

/// 多标签代码编辑器组件
pub struct EditorView {
    pub workspace_root: String,
    pub tabs: Vec<EditorTab>,
    pub active_tab_index: Option<usize>,
    #[allow(dead_code)]
    pub encoding: String,
    client: CoreClient,
}

impl EditorView {
    pub fn new(workspace_root: String, _cx: &mut Context<Self>) -> Self {
        Self {
            workspace_root,
            tabs: Vec::new(),
            active_tab_index: None,
            encoding: "UTF-8".to_string(),
            client: CoreClient::new(),
        }
    }

    /// 打开文件，如果已在标签中则切换，否则新增标签
    pub fn open_file(&mut self, path: String, content: String, cx: &mut Context<Self>) {
        if let Some(pos) = self.tabs.iter().position(|t| t.path == path) {
            self.active_tab_index = Some(pos);
            cx.notify();
            return;
        }

        let title = path
            .rsplit_once('/')
            .map(|(_, name)| name.to_string())
            .unwrap_or_else(|| path.clone());

        self.tabs.push(EditorTab {
            path,
            title,
            content,
            is_dirty: false,
            cursor_line: 1,
            cursor_col: 1,
        });

        self.active_tab_index = Some(self.tabs.len() - 1);
        cx.notify();
    }

    /// 关闭指定索引的标签页
    pub fn close_tab(&mut self, index: usize, cx: &mut Context<Self>) {
        if index < self.tabs.len() {
            self.tabs.remove(index);
            if self.tabs.is_empty() {
                self.active_tab_index = None;
            } else if let Some(current) = self.active_tab_index {
                if current >= self.tabs.len() {
                    self.active_tab_index = Some(self.tabs.len() - 1);
                }
            }
            cx.notify();
        }
    }

    /// 保存当前活动的标签页至磁盘（对接 `file.write`）
    pub fn save_active(&mut self, cx: &mut Context<Self>) {
        let Some(idx) = self.active_tab_index else {
            return;
        };
        let Some(tab) = self.tabs.get(idx) else {
            return;
        };

        let root = self.workspace_root.clone();
        let path = tab.path.clone();
        let text = tab.content.clone();
        let client = self.client.clone();

        cx.spawn(async move |this, cx| {
            let task = client.write_file(&cx, &root, &path, &text);
            if task.await.is_ok() {
                let _ = this.update(cx, |ed, cx| {
                    if let Some(active_idx) = ed.active_tab_index {
                        if let Some(t) = ed.tabs.get_mut(active_idx) {
                            if t.path == path {
                                t.is_dirty = false;
                                cx.notify();
                            }
                        }
                    }
                });
            }
        })
        .detach();
    }

    /// 获取推断的代码语言名称
    pub fn language_name(path: &str) -> &'static str {
        if path.ends_with(".rs") {
            "Rust"
        } else if path.ends_with(".json") {
            "JSON"
        } else if path.ends_with(".toml") {
            "TOML"
        } else if path.ends_with(".md") {
            "Markdown"
        } else if path.ends_with(".ts") {
            "TypeScript"
        } else if path.ends_with(".js") {
            "JavaScript"
        } else if path.ends_with(".java") {
            "Java"
        } else if path.ends_with(".xml") {
            "XML"
        } else if path.ends_with(".yaml") || path.ends_with(".yml") {
            "YAML"
        } else if path.ends_with(".sh") {
            "Shell"
        } else {
            "Plain Text"
        }
    }
}

impl Render for EditorView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let active_tab = self
            .active_tab_index
            .and_then(|idx| self.tabs.get(idx).cloned());

        v_flex()
            .size_full()
            .bg(rgb(0x13141f))
            .child(
                // 1. 顶部标签栏（Tab Bar）
                h_flex()
                    .h(px(36.0))
                    .w_full()
                    .bg(rgb(0x10111a))
                    .border_b_1()
                    .border_color(rgb(0x23263b))
                    .items_center()
                    .overflow_x_scrollbar()
                    .px_1()
                    .children(self.tabs.iter().enumerate().map(|(idx, tab)| {
                        let is_active = self.active_tab_index == Some(idx);
                        let title = tab.title.clone();
                        let is_dirty = tab.is_dirty;

                        h_flex()
                            .id(idx)
                            .h(px(32.0))
                            .items_center()
                            .gap_2()
                            .px_3()
                            .rounded_t_sm()
                            .cursor_pointer()
                            .when(is_active, |t| {
                                t.bg(rgb(0x181926)).border_t_2().border_color(rgb(0x3b82f6))
                            })
                            .when(!is_active, |t| {
                                t.bg(rgb(0x10111a)).hover(|h| h.bg(rgb(0x151624)))
                            })
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.active_tab_index = Some(idx);
                                cx.notify();
                            }))
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(if is_active {
                                        rgb(0xffffff)
                                    } else {
                                        rgb(0x9ca3af)
                                    })
                                    .child(title),
                            )
                            .when(is_dirty, |t| {
                                t.child(
                                    div()
                                        .text_xs()
                                        .text_color(rgb(0x3b82f6))
                                        .child("●"),
                                )
                            })
                            .child(
                                div()
                                    .id(("close-tab", idx))
                                    .text_xs()
                                    .text_color(rgb(0x6b7280))
                                    .hover(|h| h.text_color(rgb(0xef4444)))
                                    .child("×")
                                    .on_click(cx.listener(move |this, _event, _window, cx| {
                                        this.close_tab(idx, cx);
                                    })),
                            )
                    })),
            )
            .child(
                // 2. 中央内容编辑区
                div().flex_1().w_full().overflow_scrollbar().child(
                    if let Some(tab) = &active_tab {
                        let lines: Vec<String> = tab.content.lines().map(|s| s.to_string()).collect();

                        h_flex()
                            .size_full()
                            .p_3()
                            .gap_4()
                            .font_family("monospace")
                            .text_xs()
                            .child(
                                // 行号列
                                v_flex()
                                    .flex_shrink_0()
                                    .text_color(rgb(0x4b5563))
                                    .children((1..=lines.len().max(1)).map(|num| {
                                        div().h(px(20.0)).child(format!("{num:4}"))
                                    })),
                            )
                            .child(
                                // 代码文本列
                                v_flex()
                                    .flex_1()
                                    .text_color(rgb(0xe5e7eb))
                                    .children(lines.into_iter().enumerate().map(|(idx, line)| {
                                        div()
                                            .id(idx)
                                            .h(px(20.0))
                                            .child(if line.is_empty() { " ".to_string() } else { line })
                                    })),
                            )
                    } else {
                        // 空状态
                        h_flex()
                            .size_full()
                            .items_center()
                            .justify_center()
                            .text_sm()
                            .text_color(rgb(0x6b7280))
                            .child("No file opened. Select a file from the sidebar.")
                    },
                ),
            )
            .child(
                // 3. 底部状态栏
                h_flex()
                    .h(px(24.0))
                    .w_full()
                    .bg(rgb(0x10111a))
                    .border_t_1()
                    .border_color(rgb(0x23263b))
                    .items_center()
                    .justify_between()
                    .px_3()
                    .text_xs()
                    .text_color(rgb(0x6b7280))
                    .child(
                        h_flex().items_center().gap_3().child(if let Some(tab) = &active_tab {
                            format!("Ln {}, Col {}", tab.cursor_line, tab.cursor_col)
                        } else {
                            "Ready".to_string()
                        }),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .gap_3()
                            .child(if let Some(tab) = &active_tab {
                                Self::language_name(&tab.path)
                            } else {
                                "Plain Text"
                            })
                            .child("UTF-8")
                            .child("Lithe Core"),
                    ),
            )
    }
}
