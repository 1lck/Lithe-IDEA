//! 左侧活动栏。
//!
//! 观感对齐 macOS `LitheActivityBarButtonStyle`：37×40 的槽位里居中一个
//! 30×30 的按钮，选中时用 6pt 圆角 + 主题 selection 背景。

use std::rc::Rc;

use gpui_kit::component::Sizable as _;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, ElementId, InteractiveElement as _, IntoElement, ParentElement, RenderOnce,
    StatefulInteractiveElement as _, Styled, Window, div, px,
};

use crate::icons::{LitheIcon, icon};
use crate::{LitheMetrics, current_tokens};

/// 活动栏的一项。
pub struct ActivityRailItem {
    pub id: &'static str,
    pub icon: LitheIcon,
    pub label: &'static str,
}

impl ActivityRailItem {
    pub fn new(id: &'static str, icon: LitheIcon, label: &'static str) -> Self {
        Self { id, icon, label }
    }
}

type SelectHandler = Rc<dyn Fn(&'static str, &mut Window, &mut App) + 'static>;

/// 固定 40pt 宽的单列活动栏。
#[derive(IntoElement)]
pub struct ActivityRail {
    id: ElementId,
    items: Vec<ActivityRailItem>,
    active: Option<&'static str>,
    on_select: Option<SelectHandler>,
}

impl ActivityRail {
    pub fn new(id: impl Into<ElementId>) -> Self {
        Self {
            id: id.into(),
            items: Vec::new(),
            active: None,
            on_select: None,
        }
    }

    pub fn items(mut self, items: impl IntoIterator<Item = ActivityRailItem>) -> Self {
        self.items = items.into_iter().collect();
        self
    }

    pub fn active(mut self, id: &'static str) -> Self {
        self.active = Some(id);
        self
    }

    pub fn on_select(
        mut self,
        handler: impl Fn(&'static str, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_select = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for ActivityRail {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let ActivityRail {
            id,
            items,
            active,
            on_select,
        } = self;

        // 根节点的业务 id 用于区分同屏多个活动栏；每个槽位再拼上业务 id，
        // 不用下标，避免重排后状态错位。
        let rail_id = id.to_string();
        let mut rail = div()
            .id(id)
            .flex()
            .flex_col()
            .items_center()
            .w(px(LitheMetrics::ACTIVITY_RAIL_WIDTH))
            .h_full()
            .flex_shrink_0()
            .bg(tokens.titlebar);

        for item in items {
            let selected = active == Some(item.id);
            let item_id = item.id;
            let handler = on_select.clone();
            // 图标前景直接取 macOS 的 `toolWindowButtonText` /
            // `toolWindowSelectedText`（LitheTheme.swift:74-75），不再按
            // selection 亮度猜选中态前景。
            let foreground = if selected {
                tokens.tool_window_selected_text
            } else {
                tokens.tool_window_button_text
            };

            let button = div()
                .id(format!("{rail_id}:activity:{item_id}"))
                .size(px(LitheMetrics::ACTIVITY_BUTTON_SIZE))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(LitheMetrics::ACTIVITY_BUTTON_RADIUS))
                .when(selected, |this| this.bg(tokens.selection))
                // 选中态已经用实色背景表达，不再叠加 hover，避免颜色发脏。
                .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
                // macOS 活动栏按钮保持默认箭头光标；手型只属于链接。
                .on_click(move |_, window, cx| {
                    if let Some(handler) = &handler {
                        handler(item_id, window, cx);
                    }
                })
                .child(
                    icon(item.icon)
                        .with_size(px(LitheMetrics::ACTIVITY_ICON_SIZE))
                        .text_color(foreground),
                );

            rail = rail.child(
                div()
                    .w(px(LitheMetrics::ACTIVITY_SLOT_WIDTH))
                    .h(px(LitheMetrics::ACTIVITY_SLOT_HEIGHT))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(button),
            );
        }

        rail
    }
}
