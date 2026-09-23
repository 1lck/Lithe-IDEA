use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Context, EventEmitter, InteractiveElement as _, IntoElement, ParentElement as _,
    Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityTab {
    Explorer,
    Git,
    Search,
}

#[derive(Debug, Clone)]
pub enum ActivityRailEvent {
    SelectTab(ActivityTab),
    ToggleTerminal,
    OpenSettings,
}

pub struct ActivityRailView {
    pub active_tab: Option<ActivityTab>,
}

impl EventEmitter<ActivityRailEvent> for ActivityRailView {}

impl ActivityRailView {
    pub fn new() -> Self {
        Self {
            active_tab: Some(ActivityTab::Explorer),
        }
    }

    pub fn set_active_tab(&mut self, tab: Option<ActivityTab>, cx: &mut Context<Self>) {
        self.active_tab = tab;
        cx.notify();
    }
}

impl Render for ActivityRailView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let active = self.active_tab;

        v_flex()
            .w(px(42.0))
            .h_full()
            .bg(ThemeColors::bg_activity_rail())
            .border_r_1()
            .border_color(ThemeColors::border())
            .items_center()
            .justify_between()
            .py_2()
            .child(
                // 顶部工具窗口图标列表
                v_flex()
                    .w_full()
                    .items_center()
                    .gap_1()
                    .child(self.render_rail_button(
                        "rail-files",
                        "📁",
                        "Files (Project Explorer)",
                        active == Some(ActivityTab::Explorer),
                        ActivityRailEvent::SelectTab(ActivityTab::Explorer),
                        cx,
                    ))
                    .child(self.render_rail_button(
                        "rail-git",
                        "⎇",
                        "Version Control (Git)",
                        active == Some(ActivityTab::Git),
                        ActivityRailEvent::SelectTab(ActivityTab::Git),
                        cx,
                    ))
                    .child(self.render_rail_button(
                        "rail-search",
                        "🔍",
                        "Search Everywhere",
                        active == Some(ActivityTab::Search),
                        ActivityRailEvent::SelectTab(ActivityTab::Search),
                        cx,
                    ))
                    .child(self.render_rail_button(
                        "rail-terminal",
                        "⌨",
                        "Terminal",
                        false,
                        ActivityRailEvent::ToggleTerminal,
                        cx,
                    )),
            )
            .child(
                // 底部设置图标
                v_flex()
                    .w_full()
                    .items_center()
                    .child(self.render_rail_button(
                        "rail-settings",
                        "⚙",
                        "Settings",
                        false,
                        ActivityRailEvent::OpenSettings,
                        cx,
                    )),
            )
    }
}

impl ActivityRailView {
    fn render_rail_button(
        &self,
        id: &'static str,
        icon: &'static str,
        _tooltip: &'static str,
        is_active: bool,
        event: ActivityRailEvent,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        div()
            .id(id)
            .w(px(34.0))
            .h(px(34.0))
            .rounded_md()
            .flex()
            .items_center()
            .justify_center()
            .cursor_pointer()
            .text_sm()
            .when(is_active, |btn| {
                btn.bg(ThemeColors::bg_sidebar())
                    .text_color(ThemeColors::accent_blue())
                    .border_l_2()
                    .border_color(ThemeColors::accent_blue())
            })
            .when(!is_active, |btn| {
                btn.text_color(ThemeColors::text_muted())
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()).text_color(ThemeColors::text_primary()))
            })
            .child(icon)
            .on_click(cx.listener(move |_this, _event, _window, cx| {
                cx.emit(event.clone());
            }))
    }
}
