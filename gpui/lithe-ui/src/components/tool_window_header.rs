//! 工具窗标题栏。
//!
//! 对照 macOS `LitheToolWindowHeader`：41pt 高、13pt Bold 标题、右侧动作区，
//! 最后是折叠（隐藏）按钮。

use std::rc::Rc;

use gpui_kit::component::Sizable as _;
use gpui_kit::{
    AnyElement, App, FontWeight, InteractiveElement as _, IntoElement, ParentElement, RenderOnce,
    SharedString, StatefulInteractiveElement as _, Styled, Window, div, px,
};

use crate::icons::{LitheIcon, icon};
use crate::{LitheMetrics, current_tokens};

type CollapseHandler = Rc<dyn Fn(&mut Window, &mut App) + 'static>;

#[derive(IntoElement)]
pub struct ToolWindowHeader {
    title: SharedString,
    actions: Vec<AnyElement>,
    on_collapse: Option<CollapseHandler>,
}

impl ToolWindowHeader {
    pub fn new(title: impl Into<SharedString>) -> Self {
        Self {
            title: title.into(),
            actions: Vec::new(),
            on_collapse: None,
        }
    }

    pub fn actions(mut self, actions: impl IntoIterator<Item = AnyElement>) -> Self {
        self.actions = actions.into_iter().collect();
        self
    }

    pub fn on_collapse(mut self, handler: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        self.on_collapse = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for ToolWindowHeader {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let ToolWindowHeader {
            title,
            actions,
            on_collapse,
        } = self;

        // 标题可能重复（多个工具窗同名），因此折叠按钮的 ElementId 由标题参与生成。
        let collapse_id = format!("lithe-tool-window-header:{title}:collapse");

        let mut header = div()
            .flex()
            .flex_row()
            .items_center()
            .w_full()
            .flex_shrink_0()
            .h(px(LitheMetrics::TOOL_WINDOW_HEADER_HEIGHT))
            // 对齐 macOS `LitheToolWindowHeader` 的 HStack(spacing: 8)
            //（LitheToolWindowHeader.swift:28）与 leading 12 / trailing 8
            //（LitheToolWindowHeader.swift:47-48）。
            .gap(px(LitheMetrics::TOOL_WINDOW_HEADER_GAP))
            .pl(px(LitheMetrics::TOOL_WINDOW_HEADER_LEADING))
            .pr(px(LitheMetrics::TOOL_WINDOW_HEADER_TRAILING))
            .bg(tokens.tool_header)
            .child(
                div()
                    .min_w(px(0.0))
                    .flex_shrink_1()
                    .truncate()
                    .text_size(px(LitheMetrics::TOOL_WINDOW_TITLE_FONT_SIZE))
                    .font_weight(FontWeight::BOLD)
                    .text_color(tokens.primary_text)
                    .child(title),
            )
            // 把动作区推向右侧。
            .child(div().flex_1());

        if !actions.is_empty() {
            header = header.child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    // 对齐 macOS `ActionToolbar.actionSpacing` 的 4pt
                    //（LitheTheme.swift:520）。
                    .gap(px(LitheMetrics::TOOL_WINDOW_ACTION_GAP))
                    .children(actions),
            );
        }

        if let Some(handler) = on_collapse {
            header = header.child(
                div()
                    .id(collapse_id)
                    .size(px(LitheMetrics::TOOLBAR_ICON_BUTTON_SIZE))
                    .flex()
                    .items_center()
                    .justify_center()
                    // 对齐 macOS `LitheIconButtonStyle` 的默认圆角
                    // `Metrics.cornerRadius` = 5（LitheTheme.swift:985）。
                    .rounded(px(LitheMetrics::TOOLBAR_ICON_BUTTON_RADIUS))
                    .hover(|style| style.bg(tokens.hover))
                    .cursor_pointer()
                    .on_click(move |_, window, cx| handler(window, cx))
                    .child(
                        icon(LitheIcon::Collapse)
                            .with_size(px(LitheMetrics::TOOLBAR_ICON_SIZE))
                            .text_color(tokens.secondary_text),
                    ),
            );
        }

        header
    }
}
