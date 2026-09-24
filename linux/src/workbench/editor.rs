use gpui_kit::assets::IconName;
use gpui_kit::component::input::{Editor, EditorState, InputEvent};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, relative, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _,
    Subscription, Window,
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
///
/// 正文复用上游 `gpui_kit::component::input::Editor`，由它负责滚动、
/// 文本选择与语法高亮；本组件只管理标签栏、面包屑与文件读写。
pub struct EditorView {
    pub workspace_root: String,
    pub tabs: Vec<EditorTab>,
    pub active_tab_index: Option<usize>,
    #[allow(dead_code)]
    pub encoding: String,
    /// 当前活动标签对应的上游编辑器状态，随视图生命周期常驻并复用。
    editor_state: Entity<EditorState>,
    /// 已同步到 `editor_state` 的标签索引。
    synced_tab: Option<usize>,
    /// 活动标签内容被外部替换（重新打开文件）时置位，渲染时重新灌入编辑器。
    sync_needed: bool,
    /// 监听编辑器文本变化以回写标签内容与脏标记。
    _editor_subscription: Subscription,
    client: CoreClient,
}

impl EditorView {
    pub fn new(workspace_root: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let editor_state = cx.new(|cx| EditorState::new(window, cx).line_number(true));
        let _editor_subscription = cx.subscribe_in(
            &editor_state,
            window,
            |this, _state, event: &InputEvent, _window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.on_editor_change(cx);
                }
            },
        );

        Self {
            workspace_root,
            tabs: Vec::new(),
            active_tab_index: None,
            encoding: "UTF-8".to_string(),
            editor_state,
            synced_tab: None,
            sync_needed: false,
            _editor_subscription,
            client: CoreClient::new(),
        }
    }

    /// 打开文件，如果已在标签中则切换，否则新增标签
    pub fn open_file(&mut self, path: String, content: String, cx: &mut Context<Self>) {
        if let Some(pos) = self.tabs.iter().position(|t| t.path == path) {
            if let Some(tab) = self.tabs.get_mut(pos) {
                if tab.content != content {
                    tab.content = content;
                    tab.is_dirty = false;
                    self.sync_needed = true;
                }
            }
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
        self.sync_needed = true;
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
                } else if current > index {
                    self.active_tab_index = Some(current - 1);
                }
            }
            self.sync_needed = true;
            cx.notify();
        }
    }

    /// 把当前活动标签的文本与语言灌入上游编辑器。
    fn sync_active_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let active_index = self.active_tab_index;

        if self.synced_tab == active_index && !self.sync_needed {
            return;
        }

        let Some(index) = active_index else {
            self.synced_tab = None;
            self.sync_needed = false;
            return;
        };

        let Some(tab) = self.tabs.get(index).cloned() else {
            return;
        };

        let language = Self::language_name(&tab.path).to_lowercase();
        let content = tab.content.clone();
        self.editor_state.update(cx, |editor, cx| {
            editor.set_value(content, window, cx);
            editor.set_highlighter(language, cx);
        });

        self.synced_tab = Some(index);
        self.sync_needed = false;
    }

    /// 编辑器文本变化后回写标签内容并标记为已修改。
    fn on_editor_change(&mut self, cx: &mut Context<Self>) {
        let Some(index) = self.active_tab_index else {
            return;
        };

        let value = self.editor_state.read(cx).value().to_string();
        if let Some(tab) = self.tabs.get_mut(index) {
            if tab.content != value {
                tab.content = value;
                tab.is_dirty = true;
            }
        }
        cx.notify();
    }

    /// 保存当前活动的标签页至磁盘（对接 `file.write`）
    pub fn save_active(&mut self, cx: &mut Context<Self>) {
        let Some(idx) = self.active_tab_index else {
            return;
        };
        let Some(tab) = self.tabs.get(idx) else {
            return;
        };

        // 以编辑器内的实时文本为准，避免依赖事件回写的时序。
        let text = self.editor_state.read(cx).value().to_string();

        let root = self.workspace_root.clone();
        let path = tab.path.clone();
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
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.sync_active_editor(window, cx);

        let active_tab = self
            .active_tab_index
            .and_then(|idx| self.tabs.get(idx).cloned());

        let editor_state = self.editor_state.clone();

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
                // 3. 中央代码内容区（滚动与文本选择由上游 Editor 负责）
                div()
                    .flex_1()
                    .w_full()
                    .overflow_hidden()
                    .when_some(
                        active_tab.as_ref().map(|_| editor_state.clone()),
                        |this, state| {
                            this.child(
                                Editor::new(&state)
                                    .h(relative(1.0))
                                    .bordered(false)
                                    .readonly(false),
                            )
                        },
                    )
                    .when(active_tab.is_none(), |this| {
                        // 无打开文件空态，对齐 Tauri `EmptyEditorState`：
                        // 文件图标 + 右下角放大镜叠加，标题与描述使用 i18n 同款文案。
                        this.child(
                            h_flex()
                                .size_full()
                                .items_center()
                                .justify_center()
                                .bg(ThemeColors::bg_editor())
                                .px_6()
                                .py_8()
                                .child(
                                    v_flex()
                                        .max_w(px(448.0))
                                        .items_center()
                                        .gap_3()
                                        .child(
                                            div()
                                                .relative()
                                                .size(px(48.0))
                                                .flex()
                                                .items_center()
                                                .justify_center()
                                                .text_color(ThemeColors::text_muted())
                                                .child(Icon::new(IconName::FileText).size(px(40.0)))
                                                .child(
                                                    div().absolute().bottom_0().right_0().child(
                                                        Icon::new(IconName::Search).size(px(20.0)),
                                                    ),
                                                ),
                                        )
                                        .child(
                                            div()
                                                .text_base()
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(ThemeColors::text_primary())
                                                .child("选择文件以查看"),
                                        )
                                        .child(
                                            div()
                                                .text_sm()
                                                .text_color(ThemeColors::text_muted())
                                                .child("外部工具产生的更改会自动显示。"),
                                        ),
                                ),
                        )
                    }),
            )
    }
}
