//! 左侧活动栏组件。
//!
//! 参照 macOS `WorkbenchView.activityBar`（`macos/.../WorkbenchView.swift:1276`）
//! 与 `dockStripe`（同文件 `:1404`）：整栏 40pt 宽，每个入口占 37×40pt 槽位，
//! 槽位内居中 30×30 的按钮，图标 20pt。顶部一组是从上往下排列的左侧工具窗，
//! 底部一组是底部工具窗入口。GPUI 版本固定这七个入口，不复制 macOS 的贡献
//! 注册、拖拽排序与右键移动（按仓库规则，能让 OS 接管的交互不自定义实现）。
//!
//! 入口顺序按 macOS `WorkbenchFeatureModel.toolWindowStates` 的初始 `order`
//!（`WorkbenchFeatureModel.swift:77`）：左侧组 项目(0) / 提交(1) / 搜索(3)；
//! 底部组 `gitLog`(4) / `terminal`(5) / `problems`(8) / `run`(10)。四项都停靠
//! 在底部锚点（同文件 `:79`），点击后用底部工具窗承接内容。
//!
//! tooltip 只显示入口名称：macOS `dockStripe` 的 `help` 是
//! `renderer?.help ?? title`（`WorkbenchView.swift:1420`），不带快捷键。
//! 活动栏不是菜单入口，键位文案只出现在菜单里，避免两处各自维护一份。

use gpui_kit::component::Sizable as _;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, InteractiveElement as _, IntoElement, ParentElement as _,
    StatefulInteractiveElement as _, Styled as _, WeakEntity, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, icon};

use crate::workbench::{ToolWindow, Workbench};

/// 活动栏项目定义。
pub(crate) struct ActivityRailItemDef {
    pub id: &'static str,
    pub tool: ToolWindow,
    pub icon: LitheIcon,
    pub title: &'static str,
}

/// 顶部活动项（3 项，对齐 macOS 左侧锚点组）。
pub(crate) const TOP_ACTIVITY_ITEMS: [ActivityRailItemDef; 3] = [
    ActivityRailItemDef {
        id: "files",
        tool: ToolWindow::Project,
        icon: LitheIcon::Project,
        title: "Project",
    },
    ActivityRailItemDef {
        id: "git",
        tool: ToolWindow::Changes,
        icon: LitheIcon::Changes,
        title: "Commit",
    },
    ActivityRailItemDef {
        id: "search",
        tool: ToolWindow::Search,
        icon: LitheIcon::Search,
        title: "Search",
    },
];

/// 底部活动项（4 项，顺序对齐 macOS `toolWindowStates` 的 order：4/5/8/10）。
pub(crate) const BOTTOM_ACTIVITY_ITEMS: [ActivityRailItemDef; 4] = [
    ActivityRailItemDef {
        id: "gitLog",
        tool: ToolWindow::GitLog,
        icon: LitheIcon::GitLog,
        title: "Git Log",
    },
    ActivityRailItemDef {
        id: "terminal",
        tool: ToolWindow::Terminal,
        icon: LitheIcon::Terminal,
        title: "Terminal",
    },
    ActivityRailItemDef {
        id: "diagnostics",
        tool: ToolWindow::Problems,
        icon: LitheIcon::Problems,
        title: "Problems",
    },
    ActivityRailItemDef {
        id: "run",
        tool: ToolWindow::Run,
        icon: LitheIcon::Run,
        title: "Run",
    },
];

/// 渲染对齐 macOS 的左侧活动栏。
pub(crate) fn render_activity_rail(
    left_visible: bool,
    active_left: ToolWindow,
    bottom_visible: bool,
    active_bottom: Option<ToolWindow>,
    tokens: LitheTokens,
    owner: WeakEntity<Workbench>,
) -> AnyElement {
    let mut rail = div()
        .id("lithe-activity-rail")
        .flex()
        .flex_col()
        .items_center()
        .w(px(LitheMetrics::ACTIVITY_RAIL_WIDTH))
        .h_full()
        .flex_shrink_0()
        .bg(tokens.titlebar);

    // 顶部活动组：Project, Commit, Search
    let mut top_group = v_flex()
        .id("lithe-activity-rail-top")
        .w_full()
        .min_h(px(0.))
        .flex_shrink_0()
        .items_center();

    for item in &TOP_ACTIVITY_ITEMS {
        let selected = left_visible && active_left == item.tool;
        top_group = top_group.child(render_activity_slot(item, selected, tokens, owner.clone()));
    }

    rail = rail.child(top_group);

    // 弹性空白，将底部分组推至最底部。
    rail = rail.child(div().flex_1().min_h(px(0.)));

    // 底部活动组：Git Log, Terminal, Problems, Run
    let mut bottom_group = v_flex()
        .id("lithe-activity-rail-bottom")
        .w_full()
        .min_h(px(0.))
        .flex_shrink_0()
        .items_center();

    for item in &BOTTOM_ACTIVITY_ITEMS {
        let selected = bottom_visible && active_bottom == Some(item.tool);
        bottom_group =
            bottom_group.child(render_activity_slot(item, selected, tokens, owner.clone()));
    }

    rail = rail.child(bottom_group);

    rail.into_any_element()
}

/// 渲染活动栏上的单个槽位（37×40 槽位，居中 30×30 按钮）。
fn render_activity_slot(
    item: &ActivityRailItemDef,
    selected: bool,
    tokens: LitheTokens,
    owner: WeakEntity<Workbench>,
) -> AnyElement {
    let item_id = item.id;
    // 活动栏 tooltip 只写入口名称，对齐 macOS dockStripe 的 `help`
    //（WorkbenchView.swift:1420）：那里同样不带快捷键，键位文案只在菜单里。
    let tooltip_text = tr(item.title).to_string();

    let foreground = if selected {
        tokens.tool_window_selected_text
    } else {
        tokens.tool_window_button_text
    };

    div()
        .id(format!("lithe-activity-rail:slot:{item_id}"))
        .relative()
        .w(px(LitheMetrics::ACTIVITY_SLOT_WIDTH))
        .h(px(LitheMetrics::ACTIVITY_SLOT_HEIGHT))
        .flex()
        .items_center()
        .justify_center()
        .child(
            div()
                .id(format!("lithe-activity-rail:activity:{item_id}"))
                .size(px(LitheMetrics::ACTIVITY_BUTTON_SIZE))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(LitheMetrics::ACTIVITY_BUTTON_RADIUS))
                .when(selected, |this| this.bg(tokens.selection))
                .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
                .tooltip(move |window, cx| Tooltip::new(tooltip_text.clone()).build(window, cx))
                .on_click(move |_, window, cx| {
                    let _ = owner.update(cx, |this, cx| {
                        this.handle_activity_select(item_id, window, cx);
                    });
                })
                .child(
                    icon(item.icon)
                        .with_size(px(LitheMetrics::ACTIVITY_ICON_SIZE))
                        .text_color(foreground),
                ),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 顶部三项保持 macOS 左侧锚点组的顺序（Project → Commit → Search）。
    #[test]
    fn top_items_follow_macos_tool_window_order() {
        let ids: Vec<&str> = TOP_ACTIVITY_ITEMS.iter().map(|item| item.id).collect();
        assert_eq!(ids, ["files", "git", "search"]);
    }

    /// 底部四项的顺序是 macOS `toolWindowStates` 的初始 order（4/5/8/10），
    /// 不是按名称排序。改动常量时这个断言会挡住顺序回退。
    #[test]
    fn bottom_items_follow_macos_tool_window_order() {
        let ids: Vec<&str> = BOTTOM_ACTIVITY_ITEMS.iter().map(|item| item.id).collect();
        assert_eq!(ids, ["gitLog", "terminal", "diagnostics", "run"]);
    }
}
