//! Markdown 预览视图。
//!
//! 只负责把一段 Markdown 源文本渲染成只读文档：解析、排版、选择与滚动全部
//! 交给 gpui-kit 的 `TextView`，这里不重复实现正文样式。正文按阅读宽度居中，
//! 避免窗口很宽时一行拉得过长。
//!
//! 颜色在每次 `Render` 里从 [`current_tokens`] 取，因此主题切换后下一帧就是
//! 新配色，不需要额外的监听或缓存失效。空文本（包括只有空白的文本）显示
//! 空状态，而不是渲染一个高度为零的空白页。

use gpui_kit::component::Sizable as _;
use gpui_kit::component::text::TextView;
use gpui_kit::{
    Context, IntoElement, ParentElement as _, Render, SharedString, Styled, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, current_tokens, icon};

/// 正文的最大阅读宽度；超过后两侧留白，不再拉宽。
const PREVIEW_MAX_WIDTH: f32 = 960.0;
/// 空状态图标的边长。
const EMPTY_STATE_ICON_SIZE: f32 = 30.0;
/// 空状态图标与文字之间的间距。
const EMPTY_STATE_GAP: f32 = 8.0;

/// Markdown 预览视图。
///
/// 视图本身不持有解析结果：每次 `Render` 把当前文本交给 `TextView`，由它按
/// `id` 复用内部文档状态。`set_text` 只更新源文本并请求重绘。
pub struct MarkdownPreview {
    /// 当前展示的 Markdown 源文本。
    text: SharedString,
}

impl MarkdownPreview {
    pub fn new(_cx: &mut Context<Self>) -> Self {
        Self {
            text: SharedString::default(),
        }
    }

    /// 替换预览内容。
    ///
    /// 文本没变时不触发重绘，避免上层在每次文件保存或光标移动后无意义地
    /// 重新排版整篇文档。
    pub fn set_text(&mut self, text: String, cx: &mut Context<Self>) {
        let next = SharedString::from(text);
        if self.text == next {
            return;
        }
        self.text = next;
        cx.notify();
    }
}

impl Render for MarkdownPreview {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let text = self.text.clone();
        let has_text = !text.trim().is_empty();

        div()
            .size_full()
            .flex()
            .flex_col()
            .items_center()
            .bg(tokens.editor)
            .text_color(tokens.primary_text)
            .child(
                // 限宽容器同时负责高度：`TextView::scrollable(true)` 的根节点是
                // `size_full`，需要一个高度确定的父级才能算出滚动视口。
                div()
                    .w_full()
                    .max_w(px(PREVIEW_MAX_WIDTH))
                    .flex_1()
                    .min_h(px(0.0))
                    .flex()
                    .flex_col()
                    .child(if has_text {
                        div()
                            .flex_1()
                            .min_h(px(0.0))
                            .child(
                                TextView::markdown("lithe-markdown-preview", text)
                                    .scrollable(true)
                                    .selectable(true)
                                    .p_6(),
                            )
                            .into_any_element()
                    } else {
                        empty_state(tokens).into_any_element()
                    }),
            )
    }
}

/// 没有可预览内容时的空状态。
fn empty_state(tokens: LitheTokens) -> impl IntoElement {
    div()
        .size_full()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .gap(px(EMPTY_STATE_GAP))
        .child(
            icon(LitheIcon::Markdown)
                .with_size(px(EMPTY_STATE_ICON_SIZE))
                .text_color(tokens.tertiary_text),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::UI_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr("No preview")),
        )
}
