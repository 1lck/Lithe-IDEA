//! 工作台快速打开（Quick Open）模态视图。
//!
//! 复刻 Tauri 端 `features/quick-open` 的三模式弹层：默认按文件路径筛选，
//! 以 `@` 开头切换到当前文件符号、`#` 开头切换到工作区符号。本模块只维护
//! 查询、分组与选中态，确认后通过 [`QuickOpenEvent::OpenFile`] 把路径交给上层，
//! 不接入真实文件索引与 LSP 符号查询。

use gpui_kit::assets::IconName;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgba, AnyElement, Context, EventEmitter, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Render,
    StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;

/// 快速打开的工作模式，由查询串前缀决定。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuickOpenMode {
    /// 默认模式：按文件路径筛选。
    File,
    /// `@` 前缀：当前文件符号。
    Symbol,
    /// `#` 前缀：工作区符号。
    WorkspaceSymbol,
}

impl QuickOpenMode {
    /// 输入占位文案键（与 Tauri `quickOpen.search*` 对齐）。
    fn placeholder_key(self) -> &'static str {
        match self {
            QuickOpenMode::File => "quickOpen.searchFiles",
            QuickOpenMode::Symbol => "quickOpen.searchSymbols",
            QuickOpenMode::WorkspaceSymbol => "quickOpen.searchWorkspaceSymbols",
        }
    }

    /// 列表为空时展示的提示文案（与 Tauri `quickOpen.no*` 对齐）。
    fn empty_label(self, cx: &gpui_kit::App) -> &'static str {
        match self {
            QuickOpenMode::File => crate::i18n::menu_text(cx, "quickOpen.noMatch"),
            QuickOpenMode::Symbol | QuickOpenMode::WorkspaceSymbol => {
                crate::i18n::menu_text(cx, "quickOpen.noSymbols")
            }
        }
    }
}

/// 快速打开对外事件。
#[derive(Debug, Clone)]
pub enum QuickOpenEvent {
    /// 打开选中的文件或跳转到选中的符号，携带路径。
    OpenFile(String),
    /// 请求关闭快速打开。
    Close,
}

/// 列表渲染行：分组标题或文件项（携带该项在 `filtered` 中的位置）。
enum QuickOpenRow {
    File(usize, String),
}

/// 居中的快速打开模态，宽 704、高 420。
pub struct QuickOpenModal {
    pub query: String,
    pub mode: QuickOpenMode,
    pub files: Vec<String>,
    /// 命中筛选的文件路径，保持 `files` 的原始顺序。
    pub filtered: Vec<String>,
    pub selected_index: usize,
    pub focus_handle: FocusHandle,
    /// 最近打开的文件，用于优先分组展示。
    pub recent: Vec<String>,
}

impl EventEmitter<QuickOpenEvent> for QuickOpenModal {}

impl QuickOpenModal {
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self {
            query: String::new(),
            mode: QuickOpenMode::File,
            files: Vec::new(),
            filtered: Vec::new(),
            selected_index: 0,
            focus_handle: cx.focus_handle(),
            recent: Vec::new(),
        }
    }

    /// 替换候选文件列表并重算筛选结果。
    pub fn set_files(&mut self, files: Vec<String>, cx: &mut Context<Self>) {
        self.files = files;
        self.recompute_filtered();
        cx.notify();
    }

    /// 复位到初始状态：清空查询与选中，回到 File 模式。
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.query.clear();
        self.mode = QuickOpenMode::File;
        self.selected_index = 0;
        self.recompute_filtered();
        cx.notify();
    }

    /// 设置查询串并同步模式（`@`/`#` 前缀）与筛选结果。
    #[allow(dead_code)]
    pub fn set_query(&mut self, q: impl Into<String>, cx: &mut Context<Self>) {
        self.query = q.into();
        self.mode = mode_for_query(&self.query);
        self.selected_index = 0;
        self.recompute_filtered();
        cx.notify();
    }

    /// 在当前命中列表内移动选中项，`delta` 为正向下、为负向上，越界即夹紧。
    pub fn move_selection(&mut self, delta: i32, cx: &mut Context<Self>) {
        let total = self.filtered.len();
        if total == 0 {
            self.selected_index = 0;
        } else {
            let current = self.selected_index.min(total - 1) as i32;
            self.selected_index = (current + delta).clamp(0, total as i32 - 1) as usize;
        }
        cx.notify();
    }

    /// 当前有效选中下标（对空列表安全）。
    fn current_index(&self) -> usize {
        if self.filtered.is_empty() {
            0
        } else {
            self.selected_index.min(self.filtered.len() - 1)
        }
    }

    /// 当前用于匹配的查询串：符号模式下忽略前缀字符。
    fn effective_query(&self) -> String {
        if self.mode == QuickOpenMode::File {
            self.query.trim().to_lowercase()
        } else {
            self.query
                .trim_start_matches(|c| c == '@' || c == '#')
                .trim()
                .to_lowercase()
        }
    }

    /// 按有效查询串重算命中列表。
    fn recompute_filtered(&mut self) {
        let q = self.effective_query();
        self.filtered = self
            .files
            .iter()
            .filter(|path| q.is_empty() || path.to_lowercase().contains(&q))
            .cloned()
            .collect();
        if self.selected_index >= self.filtered.len() {
            self.selected_index = self.filtered.len().saturating_sub(1);
        }
    }

    /// 把命中列表展开为行序列（Tauri 无分组头，保持 recent 优先的扁平顺序）。
    fn build_rows(&self) -> Vec<QuickOpenRow> {
        self.filtered
            .iter()
            .enumerate()
            .map(|(position, path)| QuickOpenRow::File(position, path.clone()))
            .collect()
    }

    /// 打开命中列表第 `position` 项。
    fn open_at(&self, position: usize, cx: &mut Context<Self>) {
        if let Some(path) = self.filtered.get(position) {
            cx.emit(QuickOpenEvent::OpenFile(path.clone()));
        }
    }
}

/// 根据查询串前缀解析模式。
fn mode_for_query(query: &str) -> QuickOpenMode {
    if query.starts_with('@') {
        QuickOpenMode::Symbol
    } else if query.starts_with('#') {
        QuickOpenMode::WorkspaceSymbol
    } else {
        QuickOpenMode::File
    }
}

impl Render for QuickOpenModal {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 请求聚焦以接收按键输入
        window.focus(&self.focus_handle, cx);

        let rows = self.build_rows();
        let current_index = self.current_index();
        let mode = self.mode;

        // 全屏半透明遮罩：点击空白处关闭
        div()
            .id("quick-open-backdrop")
            .track_focus(&self.focus_handle)
            .absolute()
            .inset_0()
            .bg(rgba(0x00000088))
            .flex()
            .items_center()
            .justify_center()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                let key = event.keystroke.key.as_str();
                match key {
                    "escape" => {
                        cx.emit(QuickOpenEvent::Close);
                    }
                    "up" | "arrowup" => this.move_selection(-1, cx),
                    "down" | "arrowdown" => this.move_selection(1, cx),
                    "enter" => {
                        if !this.filtered.is_empty() {
                            let idx = this.current_index();
                            this.open_at(idx, cx);
                        }
                    }
                    "backspace" => {
                        this.query.pop();
                        this.mode = mode_for_query(&this.query);
                        this.selected_index = 0;
                        this.recompute_filtered();
                        cx.notify();
                    }
                    "space" => {
                        this.query.push(' ');
                        this.selected_index = 0;
                        this.recompute_filtered();
                        cx.notify();
                    }
                    _ => {
                        // 无修饰键时把可打印字符追加到查询串，并随前缀切换模式
                        if !event.keystroke.modifiers.control
                            && !event.keystroke.modifiers.alt
                            && !event.keystroke.modifiers.platform
                        {
                            let mut changed = false;
                            if let Some(ch) = &event.keystroke.key_char {
                                this.query.push_str(ch);
                                changed = true;
                            } else if key.chars().count() == 1 {
                                this.query.push_str(key);
                                changed = true;
                            }
                            if changed {
                                this.mode = mode_for_query(&this.query);
                                this.selected_index = 0;
                                this.recompute_filtered();
                                cx.notify();
                            }
                        }
                    }
                }
            }))
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|_this, _event, _window, cx| {
                    cx.emit(QuickOpenEvent::Close);
                }),
            )
            .child(
                v_flex()
                    .id("quick-open-card")
                    .w(px(704.0))
                    .h(px(420.0))
                    .bg(ThemeColors::surface())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded_lg()
                    .shadow_lg()
                    .overflow_hidden()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(|_this, _event, _window, cx| {
                            // 卡片内点击不冒泡到遮罩，避免误关闭
                            cx.stop_propagation();
                        }),
                    )
                    .child(
                        // 1. 顶部输入行：搜索图标 + 查询串/占位 + Esc 徽标
                        h_flex()
                            .h(px(52.0))
                            .w_full()
                            .items_center()
                            .gap_2p5()
                            .px_4()
                            .border_b_1()
                            .border_color(ThemeColors::border())
                            .child(
                                Icon::new(IconName::Search)
                                    .size(px(16.0))
                                    .text_color(ThemeColors::primary()),
                            )
                            .child(
                                h_flex()
                                    .flex_1()
                                    .items_center()
                                    .gap_1()
                                    .child(
                                        div()
                                            .text_sm()
                                            .text_color(if self.query.is_empty() {
                                                ThemeColors::subtle_foreground()
                                            } else {
                                                ThemeColors::foreground()
                                            })
                                            .child(if self.query.is_empty() {
                                                crate::i18n::menu_text(cx, mode.placeholder_key())
                                                    .to_string()
                                            } else {
                                                self.query.clone()
                                            }),
                                    )
                                    .child(
                                        // 静态光标条，提示可输入
                                        div().w(px(2.0)).h(px(16.0)).bg(ThemeColors::primary()),
                                    ),
                            )
                            .child(shortcut_badge("Esc")),
                    )
                    .child(
                        // 2. 结果列表：按 recent / other 分组，路径分段着色
                        div()
                            .flex_1()
                            .w_full()
                            .overflow_y_scrollbar()
                            .py_1()
                            .when(rows.is_empty(), |list| {
                                list.child(
                                    div()
                                        .w_full()
                                        .py_8()
                                        .text_center()
                                        .text_sm()
                                        .text_color(ThemeColors::subtle_foreground())
                                        .child(mode.empty_label(cx)),
                                )
                            })
                            .children(rows.into_iter().map(|row| match row {
                                QuickOpenRow::File(position, path) => {
                                    let is_selected = position == current_index;
                                    let is_recent = self.recent.iter().any(|r| *r == path);
                                    let (dir, name) = split_path(&path);

                                    h_flex()
                                        .id(("quick-open-item", position))
                                        .h(px(32.0))
                                        .w_full()
                                        .mx_2()
                                        .px_2p5()
                                        .items_center()
                                        .gap_2()
                                        .rounded_md()
                                        .cursor_pointer()
                                        .when(is_selected, |row| row.bg(ThemeColors::selected()))
                                        .when(!is_selected, |row| {
                                            row.hover(|h| h.bg(ThemeColors::accent()))
                                        })
                                        .child(
                                            Icon::new(IconName::FileText)
                                                .size(px(14.0))
                                                .text_color(if is_selected {
                                                    ThemeColors::primary()
                                                } else {
                                                    ThemeColors::muted_foreground()
                                                }),
                                        )
                                        .child(
                                            div()
                                                .flex_1()
                                                .text_sm()
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(ThemeColors::foreground())
                                                .child(name),
                                        )
                                        .when(!dir.is_empty(), |row| {
                                            row.child(
                                                div()
                                                    .text_xs()
                                                    .text_color(ThemeColors::subtle_foreground())
                                                    .child(dir),
                                            )
                                        })
                                        .when(is_recent, |row| {
                                            row.child(
                                                Icon::new(IconName::Clock)
                                                    .size(px(13.0))
                                                    .text_color(ThemeColors::subtle_foreground()),
                                            )
                                        })
                                        .on_click(cx.listener(move |this, _event, _window, cx| {
                                            this.open_at(position, cx);
                                        }))
                                        .into_any_element()
                                }
                            })),
                    ),
            )
    }
}

/// 把路径拆成 `(目录, 文件名)`，无目录时目录为空串。
fn split_path(path: &str) -> (String, String) {
    match path.rsplit_once('/') {
        Some((dir, name)) => (dir.to_string(), name.to_string()),
        None => (String::new(), path.to_string()),
    }
}

/// 快捷键/键位徽标。
fn shortcut_badge(label: &str) -> AnyElement {
    div()
        .px_1p5()
        .py(px(1.0))
        .rounded_sm()
        .bg(ThemeColors::accent())
        .border_1()
        .border_color(ThemeColors::border())
        .text_xs()
        .text_color(ThemeColors::muted_foreground())
        .child(label.to_string())
        .into_any_element()
}
