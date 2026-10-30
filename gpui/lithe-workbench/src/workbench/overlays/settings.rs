use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{h_flex, v_flex, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::icons::{icon, LitheIcon};
use lithe_ui::{current_tokens, LitheMetrics};

use super::super::{Workbench, OVERLAY_CONTEXT};

impl Workbench {
    /// 设置覆盖层：全屏半透明背板 + 居中 900×700 面板。
    pub(crate) fn render_settings_overlay(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let backdrop_owner = cx.weak_entity();
        let header_close_owner = cx.weak_entity();
        let footer_close_owner = cx.weak_entity();
        let restore_owner = cx.weak_entity();
        let window_size = window.window_bounds().get_bounds().size;
        let panel_width = (window_size.width - px(32.))
            .min(px(900.))
            .max(px(600.));
        let panel_height = (window_size.height - px(32.))
            .min(px(700.))
            .max(px(400.));

        div()
            .id("lithe-settings-overlay")
            .absolute()
            .inset_0()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .occlude()
            .track_focus(&self.overlay_focus)
            .key_context(OVERLAY_CONTEXT)
            .on_action(cx.listener(Self::on_action_dismiss_overlay))
            .child(
                div()
                    .id("lithe-settings-backdrop")
                    .absolute()
                    .inset_0()
                    .size_full()
                    .occlude()
                    .bg(gpui_kit::black().alpha(0.55))
                    .on_click(move |_event: &ClickEvent, _window, cx| {
                        let _ = backdrop_owner.update(cx, |this, cx| this.close_overlay(cx));
                    }),
            )
            .child(
                v_flex()
                    .id("lithe-settings-panel")
                    .occlude()
                    .w(panel_width)
                    .h(panel_height)
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .overflow_hidden()
                    .bg(tokens.editor)
                    .border_1()
                    .border_color(tokens.panel_border)
                    .child(
                        h_flex()
                            .w_full()
                            .h(px(32.))
                            .flex_shrink_0()
                            .items_center()
                            .gap(px(6.))
                            .px(px(12.))
                            .bg(tokens.editor)
                            .border_b(px(1.))
                            .border_color(tokens.divider)
                            .child(
                                icon(LitheIcon::Settings)
                                    .with_size(px(14.))
                                    .text_color(tokens.secondary_text),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.))
                                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(tokens.primary_text)
                                    .child(tr("Settings")),
                            )
                            .child(
                                Button::new("lithe-settings-close")
                                    .ghost()
                                    .size(px(24.))
                                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                                    .child(icon(LitheIcon::Close).with_size(px(14.)))
                                    .tooltip(tr("Close"))
                                    .accessibility_label(tr("Close"))
                                    .on_click(move |_, _window, cx| {
                                        let _ = header_close_owner
                                            .update(cx, |this, cx| this.close_overlay(cx));
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_h(px(0.))
                            .min_w(px(0.))
                            .when_some(self.settings_view.clone(), |this, view| this.child(view)),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .h(px(52.))
                            .flex_shrink_0()
                            .items_center()
                            .justify_between()
                            .px(px(16.))
                            .bg(tokens.editor)
                            .border_t(px(1.))
                            .border_color(tokens.divider)
                            .child(
                                Button::new("lithe-settings-restore-defaults")
                                    .small()
                                    .h(px(24.))
                                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                                    .label(tr("Restore Defaults"))
                                    .on_click(move |_, window, cx| {
                                        let _ = restore_owner.update(cx, |this, cx| {
                                            this.restore_settings_defaults(window, cx)
                                        });
                                    }),
                            )
                            .child(
                                Button::new("lithe-settings-footer-close")
                                    .small()
                                    .h(px(24.))
                                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                                    .min_w(px(72.))
                                    .label(tr("Close"))
                                    .on_click(move |_, _window, cx| {
                                        let _ = footer_close_owner
                                            .update(cx, |this, cx| this.close_overlay(cx));
                                    }),
                            ),
                    ),
            )
            .into_any_element()
    }

    pub(crate) fn restore_settings_defaults(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(view) = self.settings_view.clone() else {
            return;
        };
        view.update(cx, |view, view_cx| view.restore_defaults(window, view_cx));
    }

    pub(crate) fn toggle_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings_visible {
            self.settings_visible = false;
            cx.notify();
            return;
        }

        self.palette_visible = false;
        self.notifications_visible = false;
        self.pending_close_tab = None;
        self.project_menu_visible = false;
        self.branch_menu_visible = false;
        self.settings_visible = true;

        let settings = self.settings.clone();
        if let Some(view) = self.settings_view.clone() {
            view.update(cx, |view, view_cx| view.set_settings(settings, view_cx));
        }
        self.sync_settings_context(cx);

        self.overlay_focus.focus(window, cx);
        cx.notify();
    }
}
