//! 底部状态栏：复刻 Tauri `footer.tsx` / `footer-editor-status.tsx` /
//! `footer-status-chip.tsx`。
//!
//! 左右两组项及其顺序完全由设置（`footer_leading_items_order`、
//! `footer_trailing_items_order`）决定，与 Tauri `FOOTER_LEADING_ITEM_IDS` /
//! `FOOTER_TRAILING_ITEM_IDS` 对应。`gitChanges` chip 点击时只向外广播
//! [`StatusBarEvent::OpenGit`]，由 `view.rs` 打开 Git 侧边视图。

use gpui_kit::assets::IconName;
use gpui_kit::component::{h_flex, Icon};
use gpui_kit::{
    div, px, AnyElement, Context, EventEmitter, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::settings;
use crate::theme::ThemeColors;

/// 状态栏事件。
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum StatusBarEvent {
    /// 点击 gitChanges chip，请求打开 Git 视图。
    OpenGit,
}

#[allow(dead_code)]
pub struct StatusBarView {
    pub git_branch: Option<String>,
    pub current_file: Option<String>,
    pub cursor_line: usize,
    pub cursor_col: usize,
    pub language: String,
    pub encoding: String,
    /// 缩进宽度（空格数），来自设置的 `tab_size`。
    pub indent_size: usize,
    /// 当前编辑器是否为只读。
    pub read_only: bool,
    /// 进程内存占用（MB）。
    pub memory_mb: usize,
    /// 工作区变更文件数。
    pub git_changes: usize,
}

impl EventEmitter<StatusBarEvent> for StatusBarView {}

impl StatusBarView {
    pub fn new() -> Self {
        Self {
            git_branch: None,
            current_file: None,
            cursor_line: 1,
            cursor_col: 1,
            language: "Plain Text".to_string(),
            encoding: "UTF-8".to_string(),
            indent_size: 4,
            read_only: false,
            memory_mb: 0,
            git_changes: 0,
        }
    }

    /// 编辑器状态更新入口。签名保持不变，`view.rs` 现有调用无需改动。
    pub fn set_file_info(
        &mut self,
        file: Option<String>,
        line: usize,
        col: usize,
        lang: String,
        cx: &mut Context<Self>,
    ) {
        self.current_file = file;
        self.cursor_line = line;
        self.cursor_col = col;
        self.language = lang;
        cx.notify();
    }

    #[allow(dead_code)]
    pub fn set_git_branch(&mut self, branch: Option<String>, cx: &mut Context<Self>) {
        self.git_branch = branch;
        cx.notify();
    }

    #[allow(dead_code)]
    pub fn set_git_changes(&mut self, count: usize, cx: &mut Context<Self>) {
        self.git_changes = count;
        cx.notify();
    }

    #[allow(dead_code)]
    pub fn set_memory_mb(&mut self, mb: usize, cx: &mut Context<Self>) {
        self.memory_mb = mb;
        cx.notify();
    }
}

impl Default for StatusBarView {
    fn default() -> Self {
        Self::new()
    }
}

/// 项之间的 1px 竖向分隔线。
fn separator() -> AnyElement {
    div()
        .w(px(1.0))
        .h(px(10.0))
        .flex_shrink_0()
        .bg(ThemeColors::border())
        .into_any_element()
}

/// 带图标的标签：图标 + 文本共用同一颜色，避免两段颜色不一致。
fn labeled(icon: IconName, label: String, color: gpui_kit::Rgba) -> AnyElement {
    h_flex()
        .items_center()
        .gap_1()
        .text_color(color)
        .child(Icon::new(icon).size(px(12.0)).text_color(color))
        .child(div().child(label))
        .into_any_element()
}

impl StatusBarView {
    fn render_leading_item(&self, id: &str) -> Option<AnyElement> {
        match id {
            "filePath" => {
                let label = self
                    .current_file
                    .clone()
                    .unwrap_or_else(|| "No file active".to_string());
                Some(labeled(
                    IconName::FileText,
                    label,
                    ThemeColors::subtle_foreground(),
                ))
            }
            // 分支未知时整项不渲染，避免用占位名误导用户。
            "branch" => self
                .git_branch
                .as_ref()
                .map(|branch| labeled(IconName::GitBranch, branch.clone(), ThemeColors::success())),
            _ => None,
        }
    }

    fn render_trailing_item(&self, id: &str, cx: &mut Context<Self>) -> Option<AnyElement> {
        match id {
            "cursor" => Some(
                div()
                    .child(format!("Ln {}, Col {}", self.cursor_line, self.cursor_col))
                    .into_any_element(),
            ),
            "encoding" => Some(div().child(self.encoding.clone()).into_any_element()),
            "indent" => Some(
                div()
                    .child(format!("{} spaces", self.indent_size))
                    .into_any_element(),
            ),
            "readOnly" => Some(labeled(
                if self.read_only {
                    IconName::Lock
                } else {
                    IconName::LockOpen
                },
                if self.read_only {
                    "Read-only"
                } else {
                    "Editable"
                }
                .to_string(),
                ThemeColors::subtle_foreground(),
            )),
            "memory" => Some(labeled(
                IconName::MemoryStick,
                format!("{} MB", self.memory_mb),
                ThemeColors::subtle_foreground(),
            )),
            "gitChanges" => Some(self.render_git_changes(cx)),
            _ => None,
        }
    }

    fn render_git_changes(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.git_changes == 0 {
            // 无变更时用成功色对勾，和 Tauri 的 CheckCircleIcon text-success 对齐。
            labeled(
                IconName::CircleCheck,
                "0".to_string(),
                ThemeColors::success(),
            )
        } else {
            let count = self.git_changes;
            h_flex()
                .id("status-git-changes")
                .items_center()
                .gap_1()
                .cursor_pointer()
                .text_color(ThemeColors::git_modified())
                .hover(|h| h.bg(ThemeColors::accent()))
                .child(div().child(count.to_string()))
                .on_click(cx.listener(|_this, _event, _window, cx| {
                    cx.emit(StatusBarEvent::OpenGit);
                }))
                .into_any_element()
        }
    }
}

impl Render for StatusBarView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 只读快照顺序，随后释放对全局设置的借用。
        let (leading_order, trailing_order) = {
            let s = settings::get(cx);
            (
                s.footer_leading_items_order.clone(),
                s.footer_trailing_items_order.clone(),
            )
        };

        let leading = join_items(
            leading_order
                .iter()
                .filter_map(|id| self.render_leading_item(id)),
        );
        let trailing = join_items(
            trailing_order
                .iter()
                .filter_map(|id| self.render_trailing_item(id, cx)),
        );

        h_flex()
            .h(px(24.0))
            .w_full()
            .flex_shrink_0()
            .bg(ThemeColors::background())
            .border_t_1()
            .border_color(ThemeColors::border())
            .items_center()
            .justify_between()
            .px_3()
            .text_xs()
            .text_color(ThemeColors::subtle_foreground())
            .child(h_flex().items_center().gap_2().min_w_0().children(leading))
            .child(h_flex().items_center().gap_2().children(trailing))
    }
}

/// 用分隔线拼接一组项。
fn join_items(items: impl Iterator<Item = AnyElement>) -> Vec<AnyElement> {
    let mut out: Vec<AnyElement> = Vec::new();
    for item in items {
        if !out.is_empty() {
            out.push(separator());
        }
        out.push(item);
    }
    out
}
