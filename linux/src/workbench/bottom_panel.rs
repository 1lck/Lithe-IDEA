use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, rgb, AppContext as _, Context, Entity, IntoElement,
    ParentElement as _, Render, Styled as _, Window,
};

use crate::workbench::terminal::TerminalView;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BottomTab {
    Terminal,
    Output,
    Problems,
}

pub struct BottomPanelView {
    pub active_tab: BottomTab,
    pub is_collapsed: bool,
    pub terminal: Entity<TerminalView>,
    pub output_logs: Vec<String>,
    pub problems: Vec<String>,
}

impl BottomPanelView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let terminal = cx.new(|cx| TerminalView::new(working_dir, cx));

        Self {
            active_tab: BottomTab::Terminal,
            is_collapsed: false,
            terminal,
            output_logs: vec!["[Lithe Linux] Initialized.".to_string()],
            problems: Vec::new(),
        }
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

    pub fn append_log(&mut self, log: String, cx: &mut Context<Self>) {
        self.output_logs.push(log);
        cx.notify();
    }
}

impl Render for BottomPanelView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.is_collapsed {
            return div()
                .h(px(28.0))
                .w_full()
                .bg(rgb(0x141522))
                .border_t_1()
                .border_color(rgb(0x23263b))
                .flex()
                .items_center()
                .justify_between()
                .px_3()
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(0x8a90a2))
                        .child("Panel collapsed"),
                )
                .child(
                    Button::new("expand-panel")
                        .small()
                        .ghost()
                        .label("▲ Expand")
                        .on_click(cx.listener(|this, _event, _window, cx| {
                            this.toggle_collapsed(cx);
                        })),
                );
        }

        v_flex()
            .h(px(240.0))
            .w_full()
            .bg(rgb(0x11121d))
            .border_t_1()
            .border_color(rgb(0x23263b))
            .child(
                // 顶部 Tab 切换栏
                h_flex()
                    .h(px(32.0))
                    .w_full()
                    .bg(rgb(0x141522))
                    .border_b_1()
                    .border_color(rgb(0x23263b))
                    .items_center()
                    .justify_between()
                    .px_2()
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(
                                Button::new("tab-terminal")
                                    .small()
                                    .when(self.active_tab == BottomTab::Terminal, |btn| {
                                        btn.primary()
                                    })
                                    .when(self.active_tab != BottomTab::Terminal, |btn| {
                                        btn.ghost()
                                    })
                                    .label("Terminal")
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.set_tab(BottomTab::Terminal, cx);
                                    })),
                            )
                            .child(
                                Button::new("tab-output")
                                    .small()
                                    .when(self.active_tab == BottomTab::Output, |btn| {
                                        btn.primary()
                                    })
                                    .when(self.active_tab != BottomTab::Output, |btn| {
                                        btn.ghost()
                                    })
                                    .label("Output")
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.set_tab(BottomTab::Output, cx);
                                    })),
                            )
                            .child(
                                Button::new("tab-problems")
                                    .small()
                                    .when(self.active_tab == BottomTab::Problems, |btn| {
                                        btn.primary()
                                    })
                                    .when(self.active_tab != BottomTab::Problems, |btn| {
                                        btn.ghost()
                                    })
                                    .label(format!("Problems ({})", self.problems.len()))
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.set_tab(BottomTab::Problems, cx);
                                    })),
                            ),
                    )
                    .child(
                        Button::new("collapse-panel")
                            .small()
                            .ghost()
                            .label("▼ Hide")
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.toggle_collapsed(cx);
                            })),
                    ),
            )
            .child(
                // 内容区域根据 Tab 切换
                div().flex_1().w_full().child(match self.active_tab {
                    BottomTab::Terminal => div()
                        .size_full()
                        .child(self.terminal.clone())
                        .into_any_element(),
                    BottomTab::Output => div()
                        .size_full()
                        .p_3()
                        .overflow_y_scrollbar()
                        .text_xs()
                        .font_family("monospace")
                        .text_color(rgb(0x9ca3af))
                        .children(
                            self.output_logs
                                .iter()
                                .cloned()
                                .map(|log| div().child(log)),
                        )
                        .into_any_element(),
                    BottomTab::Problems => div()
                        .size_full()
                        .p_3()
                        .overflow_y_scrollbar()
                        .text_xs()
                        .text_color(rgb(0x9ca3af))
                        .child(if self.problems.is_empty() {
                            "No problems have been detected in the workspace.".to_string()
                        } else {
                            format!("{} problems found", self.problems.len())
                        })
                        .into_any_element(),
                }),
            )
    }
}
