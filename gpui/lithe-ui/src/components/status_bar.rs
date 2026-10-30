//! 底部状态栏。
//!
//! 对照 macOS `WorkbenchView.statusBar`：24pt 高、左右内边距 9、12pt 文字、
//! 左右两组条目，组内条目间距 10pt。macOS 没有条目分隔符，这里也不再画圆点。

use gpui_kit::component::Sizable as _;
use gpui_kit::{
    AnyElement, App, InteractiveElement as _, IntoElement, ParentElement, RenderOnce, SharedString,
    Styled, Window, div, px,
};

use crate::icons::{LitheIcon, icon};
use crate::{LitheMetrics, LitheTokens, current_tokens};

pub struct StatusBarItem {
    pub id: SharedString,
    pub text: SharedString,
    pub icon: Option<LitheIcon>,
}

impl StatusBarItem {
    pub fn new(id: impl Into<SharedString>, text: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            text: text.into(),
            icon: None,
        }
    }

    pub fn icon(mut self, icon: LitheIcon) -> Self {
        self.icon = Some(icon);
        self
    }
}

#[derive(IntoElement)]
pub struct LitheStatusBar {
    left: Vec<StatusBarItem>,
    right: Vec<StatusBarItem>,
}

impl LitheStatusBar {
    pub fn new(
        left: impl IntoIterator<Item = StatusBarItem>,
        right: impl IntoIterator<Item = StatusBarItem>,
    ) -> Self {
        Self {
            left: left.into_iter().collect(),
            right: right.into_iter().collect(),
        }
    }
}

impl RenderOnce for LitheStatusBar {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = current_tokens(cx);

        div()
            .flex()
            .flex_row()
            .items_center()
            .justify_between()
            .w_full()
            .flex_shrink_0()
            .h(px(LitheMetrics::STATUS_BAR_HEIGHT))
            // 对齐 macOS `statusBar` 的 `padding(.horizontal, 9)`
            //（WorkbenchView.swift:1695）。
            .px(px(LitheMetrics::STATUS_BAR_HORIZONTAL_PADDING))
            .bg(tokens.titlebar)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    // 对齐 macOS `compactStatusItems` 的 `HStack(spacing: 10)`
                    //（WorkbenchView.swift:1837）。
                    .gap(px(LitheMetrics::STATUS_BAR_ITEM_GAP))
                    .children(status_children(self.left, tokens)),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(LitheMetrics::STATUS_BAR_ITEM_GAP))
                    .children(status_children(self.right, tokens)),
            )
    }
}

fn status_children(items: Vec<StatusBarItem>, tokens: LitheTokens) -> Vec<AnyElement> {
    let mut children = Vec::with_capacity(items.len());
    for item in items {
        let StatusBarItem {
            id,
            text,
            icon: item_icon,
        } = item;

        // 条目的业务 id 参与 ElementId 生成；这里不按下标命名。
        let mut entry = div()
            .id(format!("lithe-status-bar:{id}"))
            .flex()
            .flex_row()
            .items_center()
            // 对齐 macOS `breadcrumbItem` 的 `HStack(spacing: 4)`
            //（WorkbenchView.swift:1760）。
            .gap(px(LitheMetrics::STATUS_BAR_ICON_GAP));

        if let Some(item_icon) = item_icon {
            entry = entry.child(
                icon(item_icon)
                    // 对齐 macOS 面包屑图标的 12pt（WorkbenchView.swift:1762）。
                    .with_size(px(LitheMetrics::STATUS_BAR_ICON_SIZE))
                    .text_color(tokens.secondary_text),
            );
        }

        entry = entry.child(
            div()
                .truncate()
                // 对齐 macOS 状态栏的 12pt `smallFont`（WorkbenchView.swift:1693）。
                .text_size(px(LitheMetrics::STATUS_BAR_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(text),
        );

        children.push(entry.into_any_element());
    }
    children
}
