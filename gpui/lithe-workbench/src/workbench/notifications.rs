use gpui_kit::component::button::{Button, ButtonVariants as _};
use lithe_ui::components::tool_window_header::ToolWindowHeader;
use gpui_kit::component::{h_flex, v_flex, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    RenderOnce as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{current_tokens, LitheMetrics, LitheTokens};

use super::{OVERLAY_CONTEXT, Workbench};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum NotificationKind {
    /// 普通信息；当前 Phase 里保存失败/成功之外的预留类别。
    #[allow(dead_code)]
    Info,
    Success,
    Error,
}

/// 通知中心的一条记录。
pub(crate) struct NotificationEntry {
    pub(super) id: u64,
    pub(super) title: SharedString,
    pub(super) message: SharedString,
    pub(super) kind: NotificationKind,
    pub(super) read: bool,
}

/// 通知中心保留的最大条数。
pub(super) const MAX_NOTIFICATIONS: usize = 100;

impl Workbench {
    /// 追加一条通知。最新的在末尾，超过上限时删除最旧的一条。
    pub(super) fn push_notification(
        &mut self,
        title: &'static str,
        message: SharedString,
        kind: NotificationKind,
    ) {
        let id = self.next_notification_id;
        self.next_notification_id = self.next_notification_id.wrapping_add(1);
        self.notifications.push(NotificationEntry {
            id,
            title: SharedString::from(title),
            message,
            kind,
            read: false,
        });
        if self.notifications.len() > MAX_NOTIFICATIONS {
            let overflow = self.notifications.len() - MAX_NOTIFICATIONS;
            self.notifications.drain(0..overflow);
        }
    }

    pub(super) fn close_notifications(&mut self, cx: &mut Context<Self>) {
        self.notifications_visible = false;
        cx.notify();
    }

    pub(super) fn clear_notifications(&mut self, cx: &mut Context<Self>) {
        self.notifications.clear();
        cx.notify();
    }

    /// 右侧通知面板，对齐 Tauri `NotificationsToolWindow`。
    pub(super) fn render_notifications_panel(
        &self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let clear_owner = cx.weak_entity();
        let collapse_owner = cx.weak_entity();

        let mut list = v_flex()
            .id("lithe-notifications-list")
            .w_full()
            .flex_1()
            .min_h(px(0.))
            .overflow_y_scroll();

        if self.notifications.is_empty() {
            list = list.child(
                div()
                    .size_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("No notifications")),
            );
        } else {
            for notification in &self.notifications {
                list = list.child(notification_row(notification, tokens));
            }
        }

        let dismiss = cx.listener(Self::on_action_dismiss_overlay);
        let header = ToolWindowHeader::new(tr("Notifications"))
            .actions([Button::new("lithe-notifications-clear")
                .ghost()
                .small()
                .label(tr("Clear"))
                .tooltip(tr("Clear"))
                .accessibility_label(tr("Clear"))
                .on_click(move |_, _window, cx| {
                    let _ = clear_owner.update(cx, |this, cx| this.clear_notifications(cx));
                })
                .into_any_element()])
            .on_collapse(move |_window, cx| {
                let _ = collapse_owner.update(cx, |this, cx| this.close_notifications(cx));
            })
            .render(_window, cx);

        v_flex()
            .id("lithe-notifications-panel")
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .rounded(px(LitheMetrics::PANE_RADIUS))
            .overflow_hidden()
            .bg(tokens.editor)
            .track_focus(&self.overlay_focus)
            .key_context(OVERLAY_CONTEXT)
            .on_action(dismiss)
            .child(header)
            .child(div().flex_1().min_h(px(0.)).child(list))
            .into_any_element()
    }
}

fn notification_row(entry: &NotificationEntry, tokens: LitheTokens) -> AnyElement {
    let kind_color = match entry.kind {
        NotificationKind::Info => tokens.accent,
        NotificationKind::Success => tokens.success,
        NotificationKind::Error => tokens.error,
    };

    h_flex()
        .id(format!("lithe-notification-row-{}", entry.id))
        .w_full()
        .items_start()
        .gap(px(8.))
        .px(px(14.))
        .py(px(10.))
        .border_b(px(1.))
        .border_color(tokens.divider)
        .child(
            div()
                .mt(px(5.))
                .size(px(6.))
                .flex_shrink_0()
                .rounded_full()
                .bg(kind_color),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w(px(0.))
                .gap(px(2.))
                .child(
                    div()
                        .w_full()
                        .truncate()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(tokens.primary_text)
                        .child(entry.title.clone()),
                )
                .child(
                    div()
                        .w_full()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(entry.message.clone()),
                ),
        )
        .when(!entry.read, |this| {
            this.child(
                div()
                    .mt(px(5.))
                    .size(px(6.))
                    .flex_shrink_0()
                    .rounded_full()
                    .bg(tokens.accent),
            )
        })
        .into_any_element()
}
