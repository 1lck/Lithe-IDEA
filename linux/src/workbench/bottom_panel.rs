use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;
use crate::workbench::terminal::TerminalView;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BottomTab {
    Terminal,
    Diagnostics,
}

pub struct BottomPanelView {
    pub active_tab: BottomTab,
    pub is_collapsed: bool,
    pub height: f32,
    pub terminal: Entity<TerminalView>,
    pub diagnostics: Vec<String>,
}

impl BottomPanelView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let terminal = cx.new(|cx| TerminalView::new(working_dir, cx));

        Self {
            active_tab: BottomTab::Terminal,
            is_collapsed: true,
            height: 240.0,
            terminal,
            diagnostics: Vec::new(),
        }
    }

    pub fn is_visible(&self) -> bool {
        !self.is_collapsed
    }

    pub fn set_height(&mut self, height: f32, cx: &mut Context<Self>) {
        self.height = height;
        cx.notify();
    }

    pub fn set_tab(&mut self, tab: BottomTab, cx: &mut Context<Self>) {
        self.active_tab = tab;
        self.is_collapsed = false;
        cx.notify();
    }

    pub fn toggle_collapsed(&mut self, cx: &mut Context<Self>) {
        self.is_collapsed = !self.is_collapsed;
        cx.notify();
    }

    /// 占位日志入口：Tauri 没有通用 Output 面板，各业务接线后改走各自面板，
    /// 当前仅保留调用点可编译，不存储不展示。
    pub fn append_log(&mut self, _log: String, _cx: &mut Context<Self>) {}

    fn render_tab_button(
        &self,
        id: &'static str,
        icon: IconName,
        label: String,
        is_active: bool,
        tab: BottomTab,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        h_flex()
            .id(id)
            .items_center()
            .gap_1p5()
            .px_3()
            .h(px(30.0))
            .cursor_pointer()
            .text_xs()
            .when(is_active, |btn| {
                btn.bg(ThemeColors::bg_bottom_panel())
                    .text_color(ThemeColors::text_primary())
                    .border_b_2()
                    .border_color(ThemeColors::accent_blue())
            })
            .when(!is_active, |btn| {
                btn.text_color(ThemeColors::text_muted()).hover(|h| {
                    h.bg(ThemeColors::bg_tab_hover())
                        .text_color(ThemeColors::text_primary())
                })
            })
            .child(Icon::new(icon).size(px(13.0)).text_color(if is_active {
                ThemeColors::accent_blue()
            } else {
                ThemeColors::text_muted()
            }))
            .child(label)
            .on_click(cx.listener(move |this, _event, _window, cx| {
                this.set_tab(tab, cx);
            }))
    }
}

impl Render for BottomPanelView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.is_collapsed {
            return div().h(px(0.0));
        }

        v_flex()
            .h(px(self.height))
            .w_full()
            .bg(ThemeColors::bg_bottom_panel())
            .border_t_1()
            .border_color(ThemeColors::border())
            .child(
                // 顶部 Tab 切换栏（高 30px）：仅保留 Tauri 存在的 Terminal / Diagnostics，
                // 自创的 Output 页签已去掉。
                h_flex()
                    .h(px(30.0))
                    .w_full()
                    .bg(ThemeColors::bg_tab_bar())
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .items_center()
                    .justify_between()
                    .px_2()
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(self.render_tab_button(
                                "tab-terminal",
                                IconName::Terminal,
                                crate::i18n::menu_text(cx, "workbench.terminal").to_string(),
                                self.active_tab == BottomTab::Terminal,
                                BottomTab::Terminal,
                                cx,
                            ))
                            .child(self.render_tab_button(
                                "tab-diagnostics",
                                IconName::TriangleAlert,
                                format!(
                                    "{} ({})",
                                    crate::i18n::menu_text(cx, "workbench.diagnostics"),
                                    self.diagnostics.len()
                                ),
                                self.active_tab == BottomTab::Diagnostics,
                                BottomTab::Diagnostics,
                                cx,
                            )),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(
                                Button::new("clear-panel")
                                    .small()
                                    .ghost()
                                    .icon(IconName::Trash)
                                    .tooltip("Clear")
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        match this.active_tab {
                                            BottomTab::Terminal => {
                                                let _ =
                                                    this.terminal.update(cx, |t, cx| t.clear(cx));
                                            }
                                            BottomTab::Diagnostics => {
                                                this.diagnostics.clear();
                                                cx.notify();
                                            }
                                        }
                                    })),
                            )
                            .child(
                                Button::new("collapse-panel")
                                    .small()
                                    .ghost()
                                    .icon(IconName::ChevronDown)
                                    .tooltip("Hide Panel")
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.toggle_collapsed(cx);
                                    })),
                            ),
                    ),
            )
            .child(
                // 内容区域根据 Tab 切换
                div().flex_1().w_full().child(match self.active_tab {
                    BottomTab::Terminal => div()
                        .size_full()
                        .child(self.terminal.clone())
                        .into_any_element(),
                    BottomTab::Diagnostics => div()
                        .size_full()
                        .p_3()
                        .overflow_y_scrollbar()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(if self.diagnostics.is_empty() {
                            "No diagnostics have been detected in the workspace.".to_string()
                        } else {
                            format!("{} diagnostics found", self.diagnostics.len())
                        })
                        .into_any_element(),
                }),
            )
    }
}
