use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    px, Context, EventEmitter, IntoElement, ParentElement as _, Render, Styled as _, Window,
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
            .w(px(40.0))
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
                        IconName::Folder,
                        "Explorer",
                        active == Some(ActivityTab::Explorer),
                        ActivityRailEvent::SelectTab(ActivityTab::Explorer),
                        cx,
                    ))
                    .child(self.render_rail_button(
                        "rail-git",
                        IconName::GitBranch,
                        "Version Control",
                        active == Some(ActivityTab::Git),
                        ActivityRailEvent::SelectTab(ActivityTab::Git),
                        cx,
                    ))
                    .child(self.render_rail_button(
                        "rail-search",
                        IconName::Search,
                        "Search Everywhere",
                        active == Some(ActivityTab::Search),
                        ActivityRailEvent::SelectTab(ActivityTab::Search),
                        cx,
                    )),
            )
            .child(
                // 底部工具按钮列表
                v_flex()
                    .w_full()
                    .items_center()
                    .gap_1()
                    .child(self.render_rail_button(
                        "rail-terminal",
                        IconName::Terminal,
                        "Terminal",
                        false,
                        ActivityRailEvent::ToggleTerminal,
                        cx,
                    ))
                    .child(self.render_rail_button(
                        "rail-settings",
                        IconName::Settings,
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
        icon: IconName,
        tooltip: &'static str,
        is_active: bool,
        event: ActivityRailEvent,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        Button::new(id)
            .ghost()
            .icon(icon)
            .tooltip(tooltip)
            .w(px(32.0))
            .h(px(32.0))
            .rounded(px(4.0))
            .text_color(if is_active {
                ThemeColors::accent_blue()
            } else {
                ThemeColors::text_muted()
            })
            .when(is_active, |btn| {
                btn.bg(ThemeColors::bg_sidebar())
                    .border_l_2()
                    .border_color(ThemeColors::accent_blue())
            })
            .on_click(cx.listener(move |_this, _event, _window, cx| {
                cx.emit(event.clone());
            }))
    }
}
