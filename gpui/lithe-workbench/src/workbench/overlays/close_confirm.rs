use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, ClickEvent, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, current_tokens};

use super::super::{OVERLAY_CONTEXT, Workbench};
use crate::layout;

impl Workbench {
    /// 未保存标签关闭确认：全屏背板 + 居中 420×180 面板。
    pub(crate) fn render_close_confirm_overlay(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let backdrop_owner = cx.weak_entity();
        let cancel_owner = cx.weak_entity();
        let discard_owner = cx.weak_entity();

        let title = self
            .pending_close_tab
            .as_ref()
            .and_then(|id| self.tabs.iter().find(|tab| &tab.id == id))
            .map(|tab| tab.title.clone())
            .unwrap_or_default();

        div()
            .id("lithe-close-confirm-overlay")
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
                    .id("lithe-close-confirm-backdrop")
                    .absolute()
                    .inset_0()
                    .size_full()
                    .occlude()
                    .bg(tokens.window.alpha(0.62))
                    .on_click(move |_event: &ClickEvent, _window, cx| {
                        let _ = backdrop_owner.update(cx, |this, cx| this.cancel_pending_close(cx));
                    }),
            )
            .child(
                v_flex()
                    .id("lithe-close-confirm-panel")
                    .occlude()
                    .w(layout::CONFIRM_CLOSE_PANEL_WIDTH)
                    .h(layout::CONFIRM_CLOSE_PANEL_HEIGHT)
                    .rounded(px(LitheMetrics::PANE_RADIUS))
                    .overflow_hidden()
                    .bg(tokens.raised)
                    .border_1()
                    .border_color(tokens.panel_border)
                    .p(px(16.))
                    .gap(px(10.))
                    .child(
                        div()
                            .w_full()
                            .text_size(px(LitheMetrics::UI_FONT_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(tr("Discard unsaved changes?")),
                    )
                    .child(
                        div()
                            .w_full()
                            .min_w(px(0.))
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(title),
                    )
                    .child(div().flex_1())
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.))
                            .child(
                                Button::new("lithe-close-confirm-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .tooltip(tr("Cancel"))
                                    .accessibility_label(tr("Cancel"))
                                    .on_click(move |_, _window, cx| {
                                        let _ = cancel_owner
                                            .update(cx, |this, cx| this.cancel_pending_close(cx));
                                    }),
                            )
                            .child(
                                Button::new("lithe-close-confirm-discard")
                                    .danger()
                                    .small()
                                    .label(tr("Discard"))
                                    .tooltip(tr("Discard"))
                                    .accessibility_label(tr("Discard"))
                                    .on_click(move |_, window, cx| {
                                        let _ = discard_owner.update(cx, |this, cx| {
                                            this.discard_pending_close(window, cx)
                                        });
                                    }),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// File > Quit 的退出入口：有未保存标签时先弹确认，否则直接退出
    /// （对齐 Tauri `requestApplicationQuit` 先走 close guard 再退出的语义）。
    pub(crate) fn request_quit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.tabs.iter().any(|tab| tab.modified) {
            self.pending_quit = true;
            self.overlay_focus.focus(window, cx);
            cx.notify();
        } else {
            cx.quit();
        }
    }

    /// 退出确认选「取消」。
    fn cancel_pending_quit(&mut self, cx: &mut Context<Self>) {
        self.pending_quit = false;
        cx.notify();
    }

    /// 退出确认选「放弃更改并退出」：不写盘，直接退出。
    fn discard_pending_quit(&mut self, cx: &mut Context<Self>) {
        self.pending_quit = false;
        cx.quit();
    }

    /// 退出确认选「全部保存并退出」：与 File > Save All 同一路径写盘后退出。
    fn save_all_and_quit(&mut self, cx: &mut Context<Self>) {
        self.pending_quit = false;
        self.editor.update(cx, |e, ecx| e.save_all(ecx));
        cx.quit();
    }

    /// 未保存退出确认：全屏背板 + 居中面板，与标签关闭确认同一套视觉。
    pub(crate) fn render_quit_confirm_overlay(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let backdrop_owner = cx.weak_entity();
        let cancel_owner = cx.weak_entity();
        let discard_owner = cx.weak_entity();
        let save_owner = cx.weak_entity();

        let dirty_count = self.tabs.iter().filter(|tab| tab.modified).count();
        let body = tr("{count} open files have unsaved changes.")
            .replace("{count}", &dirty_count.to_string());

        div()
            .id("lithe-quit-confirm-overlay")
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
                    .id("lithe-quit-confirm-backdrop")
                    .absolute()
                    .inset_0()
                    .size_full()
                    .occlude()
                    .bg(tokens.window.alpha(0.62))
                    .on_click(move |_event: &ClickEvent, _window, cx| {
                        let _ = backdrop_owner.update(cx, |this, cx| this.cancel_pending_quit(cx));
                    }),
            )
            .child(
                v_flex()
                    .id("lithe-quit-confirm-panel")
                    .occlude()
                    .w(layout::CONFIRM_CLOSE_PANEL_WIDTH)
                    .h(layout::CONFIRM_CLOSE_PANEL_HEIGHT)
                    .rounded(px(LitheMetrics::PANE_RADIUS))
                    .overflow_hidden()
                    .bg(tokens.raised)
                    .border_1()
                    .border_color(tokens.panel_border)
                    .p(px(16.))
                    .gap(px(10.))
                    .child(
                        div()
                            .w_full()
                            .text_size(px(LitheMetrics::UI_FONT_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(tr("Quit Lithe?")),
                    )
                    .child(
                        div()
                            .w_full()
                            .min_w(px(0.))
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(body),
                    )
                    .child(div().flex_1())
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.))
                            .child(
                                Button::new("lithe-quit-confirm-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .tooltip(tr("Cancel"))
                                    .accessibility_label(tr("Cancel"))
                                    .on_click(move |_, _window, cx| {
                                        let _ = cancel_owner
                                            .update(cx, |this, cx| this.cancel_pending_quit(cx));
                                    }),
                            )
                            .child(
                                Button::new("lithe-quit-confirm-discard")
                                    .danger()
                                    .small()
                                    .label(tr("Discard and Quit"))
                                    .tooltip(tr("Discard and Quit"))
                                    .accessibility_label(tr("Discard and Quit"))
                                    .on_click(move |_, _window, cx| {
                                        let _ = discard_owner
                                            .update(cx, |this, cx| this.discard_pending_quit(cx));
                                    }),
                            )
                            .child(
                                Button::new("lithe-quit-confirm-save")
                                    .primary()
                                    .small()
                                    .label(tr("Save All and Quit"))
                                    .tooltip(tr("Save All and Quit"))
                                    .accessibility_label(tr("Save All and Quit"))
                                    .on_click(move |_, _window, cx| {
                                        let _ = save_owner
                                            .update(cx, |this, cx| this.save_all_and_quit(cx));
                                    }),
                            ),
                    ),
            )
            .into_any_element()
    }
}
