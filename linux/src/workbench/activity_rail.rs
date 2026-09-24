//! 活动栏：左侧主活动栏 + 右侧插件活动栏，复刻 Tauri `sidebar-pane-selector.tsx`
//! 与 `plugin-activity-rail.tsx`。
//!
//! 左侧项顺序与可见性完全来自设置（`sidebar_activity_items_order`、
//! `hidden_sidebar_activity_items`），并按 `core_features` 过滤后端不可用项；
//! 顺序与 Tauri 的 `SIDEBAR_ACTIVITY_ITEM_IDS` / `SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS`
//! 保持一致。所有交互只通过事件向外广播，具体业务由 `view.rs` 订阅处理。

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AnyElement, Context, EventEmitter, IntoElement, ParentElement as _, Render,
    Styled as _, Window,
};

use crate::settings::{
    self, CoreFeatures, SIDEBAR_ACTIVITY_ITEM_IDS, SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS,
};
use crate::theme::ThemeColors;

/// 左侧活动栏事件。`SelectView` 只承载顶部视图类（files/git/search），
/// `ToggleBottomPane` 承载底部工具面板类，二者取值与 Tauri 的稳定 id 一致。
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum ActivityRailEvent {
    /// 切换顶部侧边视图，载荷为 "files" | "git" | "search"。
    SelectView(String),
    /// 切换底部工具窗口，载荷为 "maven" | "run" | "terminal" | "diagnostics" | "gitLog"。
    ToggleBottomPane(String),
    /// 打开设置。
    OpenSettings,
}

pub struct ActivityRailView {
    /// 当前激活的顶部视图 id；`None` 表示侧边栏整体收起。
    pub active_view: Option<String>,
    /// 当前激活的底部工具窗口 id；`None` 表示底部面板收起。
    pub active_bottom: Option<String>,
    /// 顶部组项顺序（已过滤后端能力与隐藏项）。
    top_items: Vec<&'static str>,
    /// 底部组项顺序，按 `SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS` 固定顺序排列。
    bottom_items: Vec<&'static str>,
    /// 是否发生过 Maven 运行。对齐 Tauri：左侧栏的 maven 项仅在
    /// `hasMavenRun` 为真时出现（`onMavenClick` 有条件传入）；
    /// 右侧插件栏的 Maven 入口不受此限制。
    /// Maven 运行尚未接入后端，当前恒为 false，由后续 Maven 集成调用
    /// [`ActivityRailView::set_has_maven_run`] 打开。
    #[allow(dead_code)]
    has_maven_run: bool,
}

impl EventEmitter<ActivityRailEvent> for ActivityRailView {}

impl ActivityRailView {
    /// 从设置构建活动栏项列表。
    ///
    /// 构造期只做一次快照：设置变更由 `view.rs` 重建/重订阅处理，这里不持有
    /// `App`，避免把全局状态带进渲染路径。
    pub fn new(cx: &mut Context<Self>) -> Self {
        let (top_items, bottom_items) = Self::compute_items(false, cx);

        Self {
            active_view: Some("files".to_string()),
            active_bottom: None,
            top_items,
            bottom_items,
            has_maven_run: false,
        }
    }

    /// 按设置与 `hasMavenRun` 计算左右分组。maven 仅在发生过 Maven 运行后
    /// 才出现在左侧栏，与 Tauri `main-sidebar.tsx` 的条件传入一致。
    fn compute_items(
        has_maven_run: bool,
        cx: &mut Context<Self>,
    ) -> (Vec<&'static str>, Vec<&'static str>) {
        let s = settings::get(cx);
        let ordered = normalize_order(&s.sidebar_activity_items_order);
        let features = &s.core_features;
        let hidden = &s.hidden_sidebar_activity_items;

        let visible: Vec<&'static str> = ordered
            .into_iter()
            .filter(|id| is_feature_available(id, features))
            .filter(|id| !hidden.iter().any(|h| h.as_str() == *id))
            .filter(|id| *id != "maven" || has_maven_run)
            .collect();

        // 顶部组保留可见顺序；底部组按 Tauri 常量顺序取交集，保证与参考实现一致。
        let top_items = visible
            .iter()
            .copied()
            .filter(|id| !SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS.contains(id))
            .collect();
        let bottom_items = SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS
            .iter()
            .copied()
            .filter(|id| visible.contains(id))
            .collect();
        (top_items, bottom_items)
    }

    /// 设置是否发生过 Maven 运行；为真时左侧栏出现 maven 项。
    #[allow(dead_code)]
    pub fn set_has_maven_run(&mut self, has_run: bool, cx: &mut Context<Self>) {
        self.has_maven_run = has_run;
        let (top_items, bottom_items) = Self::compute_items(has_run, cx);
        self.top_items = top_items;
        self.bottom_items = bottom_items;
        if !has_run && self.active_bottom.as_deref() == Some("maven") {
            self.active_bottom = None;
        }
        cx.notify();
    }

    pub fn set_active_view(&mut self, view: Option<String>, cx: &mut Context<Self>) {
        self.active_view = view;
        cx.notify();
    }

    pub fn set_active_bottom(&mut self, bottom: Option<String>, cx: &mut Context<Self>) {
        self.active_bottom = bottom;
        cx.notify();
    }

    /// 该 id 对应的事件出口：视图类发 `SelectView`，settings 发 `OpenSettings`，
    /// 其余底部项发 `ToggleBottomPane`。
    fn event_for(id: &'static str) -> ActivityRailEvent {
        match id {
            "files" | "git" | "search" => ActivityRailEvent::SelectView(id.to_string()),
            "settings" => ActivityRailEvent::OpenSettings,
            other => ActivityRailEvent::ToggleBottomPane(other.to_string()),
        }
    }

    fn render_item(&self, id: &'static str, cx: &mut Context<Self>) -> AnyElement {
        let (icon, tooltip) = item_meta(id);
        let is_active =
            self.active_view.as_deref() == Some(id) || self.active_bottom.as_deref() == Some(id);
        let event = Self::event_for(id);

        // 用相对容器叠加左侧 2px 高亮竖条：Button 自身不便稳定地画出单边竖条，
        // 且竖条需要压在按钮背景之上。hover 反馈由 ghost 变体内置的 accent 背景提供。
        div()
            .w(px(32.0))
            .h(px(32.0))
            .relative()
            .flex_shrink_0()
            .child(
                Button::new(format!("rail-{id}"))
                    .ghost()
                    .icon(icon)
                    .tooltip(tooltip)
                    .w(px(32.0))
                    .h(px(32.0))
                    .rounded(px(4.0))
                    .text_color(if is_active {
                        ThemeColors::primary()
                    } else {
                        ThemeColors::subtle_foreground()
                    })
                    .when(is_active, |btn| btn.bg(ThemeColors::selected()))
                    .on_click(cx.listener(move |_this, _event, _window, cx| {
                        cx.emit(event.clone());
                    })),
            )
            .when(is_active, |d| {
                d.child(
                    div()
                        .absolute()
                        .left_0()
                        .top_0()
                        .bottom_0()
                        .w(px(2.0))
                        .bg(ThemeColors::primary()),
                )
            })
            .into_any_element()
    }
}

impl Render for ActivityRailView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let top: Vec<AnyElement> = self
            .top_items
            .clone()
            .into_iter()
            .map(|id| self.render_item(id, cx))
            .collect();
        let bottom: Vec<AnyElement> = self
            .bottom_items
            .clone()
            .into_iter()
            .map(|id| self.render_item(id, cx))
            .collect();

        v_flex()
            .w(px(40.0))
            .h_full()
            .flex_shrink_0()
            .bg(ThemeColors::surface())
            .border_r_1()
            .border_color(ThemeColors::border())
            .items_center()
            .justify_between()
            .py_2()
            .child(
                // 顶部视图组
                v_flex().w_full().items_center().gap_1().children(top),
            )
            .child(
                // 底部工具组
                v_flex().w_full().items_center().gap_1().children(bottom),
            )
    }
}

/// 右侧插件活动栏事件。
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum PluginRailEvent {
    OpenExtensions,
    ToggleNotifications,
    ToggleMaven,
}

/// 右侧插件活动栏：Extensions / Notifications（带未读角标）/ Maven。
#[allow(dead_code)]
pub struct PluginActivityRailView {
    /// 通知未读数，用于角标；为 0 时不渲染角标。
    pub unread_notifications: usize,
    /// Maven 是否可用（无 Maven 项目时隐藏入口）。
    pub maven_available: bool,
}

impl EventEmitter<PluginRailEvent> for PluginActivityRailView {}

#[allow(dead_code)]
impl Default for PluginActivityRailView {
    fn default() -> Self {
        Self::new()
    }
}

#[allow(dead_code)]
impl PluginActivityRailView {
    pub fn new() -> Self {
        Self {
            unread_notifications: 3,
            maven_available: true,
        }
    }

    /// 单个插件按钮：尺寸与左侧栏按钮一致；图标沿用按钮 Medium 尺寸（16px）。
    fn render_button(
        &self,
        id: &'static str,
        icon: IconName,
        tooltip: &'static str,
        event: PluginRailEvent,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        Button::new(id)
            .ghost()
            .icon(icon)
            .tooltip(tooltip)
            .w(px(32.0))
            .h(px(32.0))
            .rounded(px(4.0))
            .text_color(ThemeColors::subtle_foreground())
            .on_click(cx.listener(move |_this, _event, _window, cx| {
                cx.emit(event.clone());
            }))
            .into_any_element()
    }
}

impl Render for PluginActivityRailView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let extensions = self.render_button(
            "plugin-extensions",
            IconName::Puzzle,
            "Extensions",
            PluginRailEvent::OpenExtensions,
            cx,
        );
        let maven = self.maven_available.then(|| {
            self.render_button(
                "plugin-maven",
                IconName::Box,
                "Maven",
                PluginRailEvent::ToggleMaven,
                cx,
            )
        });

        v_flex()
            .w(px(38.0))
            .h_full()
            .flex_shrink_0()
            .bg(ThemeColors::surface())
            .border_l_1()
            .border_color(ThemeColors::border())
            .items_center()
            .pt_1()
            .gap_1()
            .child(extensions)
            .child(
                // 通知按钮 + 右上角未读角标。角标叠加在按钮容器上，避免撑开按钮尺寸。
                div()
                    .w(px(32.0))
                    .h(px(32.0))
                    .relative()
                    .flex_shrink_0()
                    .child(self.render_button(
                        "plugin-notifications",
                        IconName::Bell,
                        "Notifications",
                        PluginRailEvent::ToggleNotifications,
                        cx,
                    ))
                    .when(self.unread_notifications > 0, |d| {
                        // 超过 9 条统一显示 9+，避免角标随数字变宽。
                        let label = if self.unread_notifications > 9 {
                            "9+".to_string()
                        } else {
                            self.unread_notifications.to_string()
                        };
                        d.child(
                            h_flex()
                                .absolute()
                                .top_0()
                                .right_0()
                                .min_w(px(14.0))
                                .h(px(14.0))
                                .rounded_full()
                                .bg(ThemeColors::destructive())
                                .items_center()
                                .justify_center()
                                .text_xs()
                                .text_color(gpui_kit::white())
                                .child(label),
                        )
                    }),
            )
            .when_some(maven, |rail, maven| rail.child(maven))
    }
}

/// id → 图标与 tooltip（含快捷键，文案对齐 Tauri）。
fn item_meta(id: &str) -> (IconName, &'static str) {
    match id {
        "files" => (IconName::Files, "Files (Ctrl+Shift+E)"),
        "git" => (IconName::GitBranch, "Version Control (Ctrl+Shift+G)"),
        "search" => (IconName::Search, "Search (Ctrl+Shift+F)"),
        "maven" => (IconName::Box, "Maven"),
        "run" => (IconName::Play, "Run (Shift+F10)"),
        "terminal" => (IconName::Terminal, "Terminal (Ctrl+J)"),
        "diagnostics" => (IconName::TriangleAlert, "Problems (Ctrl+Shift+J)"),
        "gitLog" => (IconName::GitGraph, "Git Graph (Alt+9)"),
        _ => (IconName::Settings, "Settings"),
    }
}

/// 把持久化顺序规范化成合法且无重复的静态 id 列表，缺失项按默认顺序补齐，
/// 对齐 Tauri `normalizeItemOrder`。
fn normalize_order(persisted: &[String]) -> Vec<&'static str> {
    let mut out: Vec<&'static str> = Vec::new();
    for id in persisted {
        if let Some(known) = static_id(id) {
            if !out.contains(&known) {
                out.push(known);
            }
        }
    }
    for id in SIDEBAR_ACTIVITY_ITEM_IDS.iter().copied() {
        if !out.contains(&id) {
            out.push(id);
        }
    }
    out
}

fn static_id(id: &str) -> Option<&'static str> {
    SIDEBAR_ACTIVITY_ITEM_IDS
        .iter()
        .copied()
        .find(|known| *known == id)
}

/// 按后端能力过滤：search/git(含 gitLog)/terminal/diagnostics 由 `core_features`
/// 控制，其余（files/maven/run/settings）始终可见，对齐 Tauri
/// `sidebarActivityVisibilityItemIds`。
fn is_feature_available(id: &str, features: &CoreFeatures) -> bool {
    match id {
        "search" => features.search,
        "git" | "gitLog" => features.git,
        "terminal" => features.terminal,
        "diagnostics" => features.diagnostics,
        _ => true,
    }
}
