use gpui_kit::assets::IconName;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::core::CoreClient;
use crate::theme::ThemeColors;

#[derive(Debug, Clone)]
pub struct EditorTab {
    pub path: String,
    pub title: String,
    pub content: String,
    pub is_dirty: bool,
    #[allow(dead_code)]
    pub cursor_line: usize,
    #[allow(dead_code)]
    pub cursor_col: usize,
}

/// 多标签代码编辑器组件（对齐 macOS LitheTheme / IntelliJ 视觉规范）
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
        } else if path.ends_with(".sql") {
            "SQL"
        } else {
            "Plain Text"
        }
    }
}

fn is_code_file(name: &str) -> bool {
    let lower = name.to_lowercase();
    lower.ends_with(".rs")
        || lower.ends_with(".js")
        || lower.ends_with(".ts")
        || lower.ends_with(".jsx")
        || lower.ends_with(".tsx")
        || lower.ends_with(".json")
        || lower.ends_with(".toml")
        || lower.ends_with(".html")
        || lower.ends_with(".css")
        || lower.ends_with(".java")
        || lower.ends_with(".c")
        || lower.ends_with(".cpp")
        || lower.ends_with(".h")
        || lower.ends_with(".hpp")
        || lower.ends_with(".py")
        || lower.ends_with(".go")
        || lower.ends_with(".swift")
        || lower.ends_with(".sh")
        || lower.ends_with(".xml")
        || lower.ends_with(".yaml")
        || lower.ends_with(".yml")
        || lower.ends_with(".sql")
}

impl Render for EditorView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let active_tab = self
            .active_tab_index
            .and_then(|idx| self.tabs.get(idx).cloned());

        v_flex()
            .size_full()
            .bg(ThemeColors::bg_editor())
            .child(
                // 1. 顶部标签栏（Tab Bar，高 34px）
                h_flex()
                    .h(px(34.0))
                    .w_full()
                    .bg(ThemeColors::bg_tab_bar())
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .items_center()
                    .overflow_x_scrollbar()
                    .children(self.tabs.iter().enumerate().map(|(idx, tab)| {
                        let is_active = self.active_tab_index == Some(idx);
                        let title = tab.title.clone();
                        let is_dirty = tab.is_dirty;
                        let icon_name = if is_code_file(&title) {
                            IconName::FileCode
                        } else {
                            IconName::FileText
                        };

                        h_flex()
                            .id(idx)
                            .h(px(34.0))
                            .items_center()
                            .gap_2()
                            .px_3()
                            .relative()
                            .cursor_pointer()
                            .when(is_active, |t| t.bg(ThemeColors::bg_editor()))
                            .when(!is_active, |t| {
                                t.bg(ThemeColors::bg_tab_bar())
                                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                            })
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.active_tab_index = Some(idx);
                                cx.notify();
                            }))
                            .child(
                                Icon::new(icon_name)
                                    .size(px(14.0))
                                    .text_color(if is_active {
                                        ThemeColors::accent_blue()
                                    } else {
                                        ThemeColors::text_muted()
                                    }),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(if is_active {
                                        ThemeColors::text_primary()
                                    } else {
                                        ThemeColors::text_muted()
                                    })
                                    .child(title),
                            )
                            .when(is_dirty, |t| {
                                t.child(
                                    div()
                                        .w(px(6.0))
                                        .h(px(6.0))
                                        .rounded_full()
                                        .bg(ThemeColors::accent_blue()),
                                )
                            })
                            .child(
                                div()
                                    .id(("close-tab", idx))
                                    .p(px(2.0))
                                    .rounded_sm()
                                    .cursor_pointer()
                                    .hover(|h| {
                                        h.bg(ThemeColors::bg_tab_hover())
                                            .text_color(ThemeColors::accent_red())
                                    })
                                    .child(
                                        Icon::new(IconName::Close)
                                            .size(px(12.0))
                                            .text_color(ThemeColors::text_muted()),
                                    )
                                    .on_click(cx.listener(move |this, _event, _window, cx| {
                                        this.close_tab(idx, cx);
                                    })),
                            )
                            // 激活 Tab 底部 2px 高亮条（对齐 macOS tabUnderline）
                            .when(is_active, |t| {
                                t.child(
                                    div()
                                        .absolute()
                                        .bottom_0()
                                        .left_0()
                                        .right_0()
                                        .h(px(2.0))
                                        .bg(ThemeColors::accent_blue()),
                                )
                            })
                    })),
            )
            .when_some(active_tab.as_ref(), |this, tab| {
                // 2. 面包屑导航栏（Breadcrumb Bar，高 24px）
                let segments: Vec<&str> = tab.path.split('/').filter(|s| !s.is_empty()).collect();
                let last_idx = segments.len().saturating_sub(1);

                this.child(
                    h_flex()
                        .h(px(24.0))
                        .w_full()
                        .bg(ThemeColors::bg_tab_active())
                        .border_b_1()
                        .border_color(ThemeColors::border())
                        .items_center()
                        .px_3()
                        .gap_1p5()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(
                            Icon::new(IconName::Folder)
                                .size(px(12.0))
                                .text_color(ThemeColors::text_muted()),
                        )
                        .children(segments.into_iter().enumerate().flat_map(|(idx, seg)| {
                            let is_last = idx == last_idx;
                            let seg_element = div()
                                .text_xs()
                                .text_color(if is_last {
                                    ThemeColors::text_primary()
                                } else {
                                    ThemeColors::text_muted()
                                })
                                .child(seg.to_string())
                                .into_any_element();

                            if is_last {
                                vec![seg_element]
                            } else {
                                vec![
                                    seg_element,
                                    Icon::new(IconName::ChevronRight)
                                        .size(px(10.0))
                                        .text_color(ThemeColors::text_muted())
                                        .into_any_element(),
                                ]
                            }
                        })),
                )
            })
            .child(
                // 3. 中央代码内容区
                div().flex_1().w_full().overflow_scrollbar().child(
                    if let Some(tab) = &active_tab {
                        let lines: Vec<String> = tab.content.lines().map(|s| s.to_string()).collect();
                        let total_lines = lines.len().max(1);

                        h_flex()
                            .size_full()
                            .p_2()
                            .font_family("monospace")
                            .text_xs()
                            .child(
                                // 代码行号槽（Gutter）
                                v_flex()
                                    .flex_shrink_0()
                                    .w(px(48.0))
                                    .pr_3()
                                    .border_r_1()
                                    .border_color(ThemeColors::border())
                                    .text_color(ThemeColors::text_muted())
                                    .items_end()
                                    .children((1..=total_lines).map(|num| {
                                        div().h(px(20.0)).child(format!("{num}"))
                                    })),
                            )
                            .child(
                                // 代码文本展示行
                                v_flex()
                                    .flex_1()
                                    .pl_3()
                                    .text_color(ThemeColors::text_primary())
                                    .children(lines.into_iter().enumerate().map(|(idx, line)| {
                                        div()
                                            .id(idx)
                                            .h(px(20.0))
                                            .child(if line.is_empty() { " ".to_string() } else { line })
                                    })),
                            )
                    } else {
                        // 无打开文件 Empty State（精致 Lithe 居中徽标与操作提示）
                        h_flex()
                            .size_full()
                            .items_center()
                            .justify_center()
                            .child(
                                v_flex()
                                    .items_center()
                                    .gap_3()
                                    .child(
                                        Icon::new(IconName::Zap)
                                            .size(px(48.0))
                                            .text_color(ThemeColors::accent_blue()),
                                    )
                                    .child(
                                        div()
                                            .text_lg()
                                            .font_weight(FontWeight::BOLD)
                                            .text_color(ThemeColors::text_primary())
                                            .child("Lithe IDEA"),
                                    )
                                    .child(
                                        div()
                                            .text_xs()
                                            .text_color(ThemeColors::text_muted())
                                            .child("Next-generation IDE for Linux, powered by GPUI Kit & Rust Core"),
                                    )
                                    .child(
                                        v_flex()
                                            .pt_2()
                                            .gap_2()
                                            .child(
                                                h_flex()
                                                    .items_center()
                                                    .gap_2()
                                                    .text_xs()
                                                    .text_color(ThemeColors::text_muted())
                                                    .child("Search files everywhere:")
                                                    .child(
                                                        div()
                                                            .px_1p5()
                                                            .py(px(1.0))
                                                            .bg(ThemeColors::bg_tab_hover())
                                                            .border_1()
                                                            .border_color(ThemeColors::border())
                                                            .rounded_sm()
                                                            .text_color(ThemeColors::text_primary())
                                                            .child("Ctrl+P"),
                                                    ),
                                            )
                                            .child(
                                                h_flex()
                                                    .items_center()
                                                    .gap_2()
                                                    .text_xs()
                                                    .text_color(ThemeColors::text_muted())
                                                    .child("Toggle terminal panel:")
                                                    .child(
                                                        div()
                                                            .px_1p5()
                                                            .py(px(1.0))
                                                            .bg(ThemeColors::bg_tab_hover())
                                                            .border_1()
                                                            .border_color(ThemeColors::border())
                                                            .rounded_sm()
                                                            .text_color(ThemeColors::text_primary())
                                                            .child("Ctrl+`"),
                                                    ),
                                            ),
                                    ),
                            )
                    },
                ),
            )
    }
}
