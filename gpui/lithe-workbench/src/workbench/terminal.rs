use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::{
    AnyElement, AppContext as _, Context, InteractiveElement as _, IntoElement, ParentElement as _, Styled as _,
    Window, div, px,
};
use lithe_features::TerminalPanel;
use lithe_ui::i18n::tr;
use lithe_ui::icons::{icon, LitheIcon};
use lithe_ui::{current_tokens, LitheMetrics};

use super::dock::{DockAnchor, ToolWindow};
use super::Workbench;
use crate::top_bar::TOOL_WINDOW_HEADER_BUTTON_RADIUS;

/// 终端标签条高度：对齐 Tauri `--lithe-tab-bar-height`。
pub(super) const TERMINAL_TAB_BAR_HEIGHT: f32 = 36.0;
/// 终端标签高度：对齐 Tauri `--lithe-tab-height`。
pub(super) const TERMINAL_TAB_HEIGHT: f32 = 28.0;
/// 终端标签条右侧动作按钮：Tauri `size="icon-xs"`（24×24）。
pub(super) const TERMINAL_TAB_ACTION_SIZE: f32 = 24.0;

/// 终端分屏方向。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TerminalSplitAxis {
    Horizontal,
    Vertical,
}

impl Workbench {
    /// 终端面板的标签条，对齐 Tauri `TerminalTabBar`。
    pub(super) fn render_terminal_tab_bar(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let clear_owner = cx.weak_entity();
        let split_right_owner = cx.weak_entity();
        let split_down_owner = cx.weak_entity();
        let close_split_owner = cx.weak_entity();
        let hide_owner = cx.weak_entity();
        let has_split = self.terminal_secondary.is_some();

        let mut actions = vec![Button::new("lithe-terminal-clear")
            .ghost()
            .with_size(px(TERMINAL_TAB_ACTION_SIZE))
            .rounded(px(TOOL_WINDOW_HEADER_BUTTON_RADIUS))
            .icon(Icon::new(IconName::Eraser))
            .tooltip(tr("Clear"))
            .accessibility_label(tr("Clear"))
            .on_click(move |_, _window, cx| {
                let _ = clear_owner.update(cx, |this, cx| {
                    this.terminal
                        .update(cx, |panel, panel_cx| panel.clear(panel_cx));
                    cx.notify();
                });
            })
            .into_any_element()];

        if has_split {
            actions.push(
                Button::new("lithe-terminal-close-split")
                    .ghost()
                    .with_size(px(TERMINAL_TAB_ACTION_SIZE))
                    .rounded(px(TOOL_WINDOW_HEADER_BUTTON_RADIUS))
                    .icon(Icon::new(IconName::X))
                    .tooltip(tr("Close Split"))
                    .accessibility_label(tr("Close Split"))
                    .on_click(move |_, _window, cx| {
                        let _ = close_split_owner
                            .update(cx, |this, cx| this.close_terminal_split(cx));
                    })
                    .into_any_element(),
            );
        } else {
            actions.push(
                Button::new("lithe-terminal-split-right")
                    .ghost()
                    .with_size(px(TERMINAL_TAB_ACTION_SIZE))
                    .rounded(px(TOOL_WINDOW_HEADER_BUTTON_RADIUS))
                    .icon(Icon::new(IconName::PanelRight))
                    .tooltip(tr("Split Terminal Right"))
                    .accessibility_label(tr("Split Terminal Right"))
                    .on_click(move |_, window, cx| {
                        let _ = split_right_owner.update(cx, |this, cx| {
                            this.split_terminal(TerminalSplitAxis::Horizontal, window, cx);
                        });
                    })
                    .into_any_element(),
            );
            actions.push(
                Button::new("lithe-terminal-split-down")
                    .ghost()
                    .with_size(px(TERMINAL_TAB_ACTION_SIZE))
                    .rounded(px(TOOL_WINDOW_HEADER_BUTTON_RADIUS))
                    .icon(Icon::new(IconName::PanelBottom))
                    .tooltip(tr("Split Terminal Down"))
                    .accessibility_label(tr("Split Terminal Down"))
                    .on_click(move |_, window, cx| {
                        let _ = split_down_owner.update(cx, |this, cx| {
                            this.split_terminal(TerminalSplitAxis::Vertical, window, cx);
                        });
                    })
                    .into_any_element(),
            );
        }

        actions.push(
            Button::new("lithe-terminal-hide")
                .ghost()
                .with_size(px(TERMINAL_TAB_ACTION_SIZE))
                .rounded(px(TOOL_WINDOW_HEADER_BUTTON_RADIUS))
                .icon(Icon::new(IconName::Minus))
                .tooltip(tr("Minimize Terminal"))
                .accessibility_label(tr("Minimize Terminal"))
                .on_click(move |_, _window, cx| {
                    let _ = hide_owner.update(cx, |this, cx| {
                        this.set_dock_visible(DockAnchor::Bottom, false, cx);
                    });
                })
                .into_any_element(),
        );

        h_flex()
            .id("lithe-terminal-tab-bar")
            .w_full()
            .h(px(TERMINAL_TAB_BAR_HEIGHT))
            .flex_shrink_0()
            .items_center()
            .gap(px(4.))
            .px(px(8.))
            .bg(tokens.tool_header)
            .border_b(px(1.))
            .border_color(tokens.divider)
            .child(
                h_flex()
                    .h(px(TERMINAL_TAB_HEIGHT))
                    .items_center()
                    .gap(px(6.))
                    .px(px(8.))
                    .rounded(px(4.))
                    .bg(tokens.selection)
                    .child(
                        icon(LitheIcon::Terminal)
                            .with_size(px(16.))
                            .text_color(tokens.primary_text),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(tr("Terminal")),
                    ),
            )
            .child(div().flex_1())
            .children(actions)
            .into_any_element()
    }

    /// 终端内容视图。
    pub(super) fn render_terminal_content(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(secondary) = self.terminal_secondary.clone() else {
            return self.terminal.clone().into_any_element();
        };

        let tokens = current_tokens(cx);
        let primary = div()
            .flex_1()
            .min_w(px(0.))
            .min_h(px(0.))
            .child(self.terminal.clone());
        let secondary_pane = div().flex_1().min_w(px(0.)).min_h(px(0.)).child(secondary);

        match self.terminal_split_axis {
            TerminalSplitAxis::Horizontal => h_flex()
                .items_stretch()
                .size_full()
                .min_w(px(0.))
                .min_h(px(0.))
                .child(primary)
                .child(div().flex_shrink_0().w(px(1.)).bg(tokens.divider))
                .child(secondary_pane)
                .into_any_element(),
            TerminalSplitAxis::Vertical => v_flex()
                .size_full()
                .min_w(px(0.))
                .min_h(px(0.))
                .child(primary)
                .child(div().flex_shrink_0().h(px(1.)).bg(tokens.divider))
                .child(secondary_pane)
                .into_any_element(),
        }
    }

    pub(super) fn split_terminal(
        &mut self,
        axis: TerminalSplitAxis,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.show_tool(ToolWindow::Terminal, window, cx);
        self.terminal_split_axis = axis;
        self.terminal_focus_secondary = true;

        if let Some(panel) = self.terminal_secondary.clone() {
            panel.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
            cx.notify();
            return;
        }

        let root = self.project_root.clone().unwrap_or_default();
        let panel = cx.new(|panel_cx| TerminalPanel::new(root, window, panel_cx));
        let font_size = self.settings.terminal_font_size;
        let scrollback = self.settings.terminal_scrollback;
        panel.update(cx, |panel, panel_cx| {
            panel.set_preferences(font_size, scrollback, window, panel_cx);
        });
        panel.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
        self.terminal_secondary = Some(panel);
        self.terminal_secondary_webview_visible = None;
        cx.notify();
    }

    pub(super) fn close_terminal_split(&mut self, cx: &mut Context<Self>) {
        let Some(panel) = self.terminal_secondary.take() else {
            return;
        };
        panel.update(cx, |panel, panel_cx| {
            panel.set_webview_visible(false, panel_cx);
        });
        self.terminal_secondary_webview_visible = None;
        self.terminal_focus_secondary = false;
        cx.notify();
    }

    pub(super) fn apply_terminal_preferences(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let font_size = self.settings.terminal_font_size;
        let scrollback = self.settings.terminal_scrollback;
        self.terminal.update(cx, |panel, panel_cx| {
            panel.set_preferences(font_size, scrollback, window, panel_cx);
        });
        if let Some(panel) = self.terminal_secondary.clone() {
            panel.update(cx, |panel, panel_cx| {
                panel.set_preferences(font_size, scrollback, window, panel_cx);
            });
        }
    }
}
