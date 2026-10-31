//! 左侧活动栏组件（完全对齐 Tauri 侧 SidebarActivityRail 实现）。
//!
//! 唯一事实来源：`windows/tauri/src/features/layout/config/item-order.ts`
//! 与 `sidebar-pane-selector.tsx`。
//!
//! 布局结构：
//! - 顶部 3 项：
//!   1. `files` (项目): `Mod+Shift+E`, `LitheIcon::Project`
//!   2. `git` (提交): `Mod+Shift+G`, `LitheIcon::Changes`
//!   3. `search` (搜索): `Mod+Shift+F`, `LitheIcon::Search`
//! - 中间：弹性占位空白（`flex: 1`）
//! - 底部 4 项（`SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS`）：
//!   4. `run` (运行): `Shift+F10`, `LitheIcon::Run`
//!   5. `terminal` (终端): `Mod+J`, `LitheIcon::Terminal`
//!   6. `diagnostics` (问题): `Mod+Shift+J`, `LitheIcon::Problems`
//!   7. `gitLog` (Git 日志): `Alt+9`, `LitheIcon::GitLog`

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
    pub shortcut: &'static str,
}

/// 顶部活动项（3 项，对齐 Tauri 的顶部分组）。
pub(crate) const TOP_ACTIVITY_ITEMS: [ActivityRailItemDef; 3] = [
    ActivityRailItemDef {
        id: "files",
        tool: ToolWindow::Project,
        icon: LitheIcon::Project,
        title: "Project",
        shortcut: "Mod+Shift+E",
    },
    ActivityRailItemDef {
        id: "git",
        tool: ToolWindow::Changes,
        icon: LitheIcon::Changes,
        title: "Commit",
        shortcut: "Mod+Shift+G",
    },
    ActivityRailItemDef {
        id: "search",
        tool: ToolWindow::Search,
        icon: LitheIcon::Search,
        title: "Search",
        shortcut: "Mod+Shift+F",
    },
];

/// 底部活动项（4 项，对齐 Tauri 的 SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS）。
pub(crate) const BOTTOM_ACTIVITY_ITEMS: [ActivityRailItemDef; 4] = [
    ActivityRailItemDef {
        id: "run",
        tool: ToolWindow::Run,
        icon: LitheIcon::Run,
        title: "Run",
        shortcut: "Shift+F10",
    },
    ActivityRailItemDef {
        id: "terminal",
        tool: ToolWindow::Terminal,
        icon: LitheIcon::Terminal,
        title: "Terminal",
        shortcut: "Mod+J",
    },
    ActivityRailItemDef {
        id: "diagnostics",
        tool: ToolWindow::Problems,
        icon: LitheIcon::Problems,
        title: "Problems",
        shortcut: "Mod+Shift+J",
    },
    ActivityRailItemDef {
        id: "gitLog",
        tool: ToolWindow::GitLog,
        icon: LitheIcon::GitLog,
        title: "Git Log",
        shortcut: "Alt+9",
    },
];

/// 格式化对平台友好的快捷键展示文本。
fn format_platform_shortcut(shortcut: &'static str) -> String {
    if cfg!(target_os = "macos") {
        shortcut
            .replace("Mod+", "⌘")
            .replace("Shift+", "⇧")
            .replace("Alt+", "⌥")
            .replace("Ctrl+", "⌃")
    } else {
        shortcut
            .replace("Mod+", "Ctrl+")
            .replace("Shift+", "Shift+")
            .replace("Alt+", "Alt+")
    }
}

/// 渲染对齐 Tauri 的左侧活动栏。
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

    // 弹性空白，将底部分组推至最底部
    rail = rail.child(div().flex_1().min_h(px(0.)));

    // 底部活动组：Run, Terminal, Diagnostics, Git Log
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
    let label = tr(item.title);
    let shortcut_hint = format_platform_shortcut(item.shortcut);
    let tooltip_text = format!("{label} ({shortcut_hint})");

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
