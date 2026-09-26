use gpui::prelude::*;
use gpui::{div, px, App, ClickEvent, ElementId, FontWeight, SharedString, Window};
use rgitui_theme::{ActiveTheme, Color, StyledExt};

use crate::{ButtonSize, Icon, IconButton, IconName, IconSize, Label, LabelSize};

/// The severity level of a toast notification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToastLevel {
    Success,
    Error,
    Warning,
    Info,
}

impl ToastLevel {
    pub fn color(&self) -> Color {
        match self {
            ToastLevel::Success => Color::Success,
            ToastLevel::Error => Color::Error,
            ToastLevel::Warning => Color::Warning,
            ToastLevel::Info => Color::Info,
        }
    }

    pub fn icon(&self) -> IconName {
        match self {
            ToastLevel::Success => IconName::CheckCircle,
            ToastLevel::Error => IconName::XCircle,
            ToastLevel::Warning => IconName::AlertTriangle,
            ToastLevel::Info => IconName::Info,
        }
    }

    /// A short severity word used as a text prefix so the level is
    /// distinguishable without relying on color perception.
    pub fn label(&self) -> &'static str {
        match self {
            ToastLevel::Success => "Success",
            ToastLevel::Error => "Error",
            ToastLevel::Warning => "Warning",
            ToastLevel::Info => "Info",
        }
    }

    /// How long a toast of this level stays on screen, or `None` when it must
    /// wait to be dismissed.
    ///
    /// A single hardcoded three seconds meant errors vanished before they
    /// could be read, and a "Generating..." notice expired mid-operation on a
    /// tool-calling generation that runs 30s or more.
    pub fn auto_dismiss_after(&self) -> Option<std::time::Duration> {
        match self {
            ToastLevel::Success | ToastLevel::Info => Some(std::time::Duration::from_secs(3)),
            ToastLevel::Warning => Some(std::time::Duration::from_secs(6)),
            // Sticky. An error the user never saw is an error they cannot act
            // on.
            ToastLevel::Error => None,
        }
    }
}

/// A compact toast notification pill component.
///
/// Renders as a small rounded pill with an icon and message text,
/// styled according to the notification level.
#[derive(IntoElement)]
pub struct Toast {
    id: ElementId,
    message: SharedString,
    level: ToastLevel,
    on_dismiss: Option<crate::ClickHandler>,
    action: Option<(SharedString, crate::ClickHandler)>,
}

impl Toast {
    pub fn new(
        id: impl Into<ElementId>,
        message: impl Into<SharedString>,
        level: ToastLevel,
    ) -> Self {
        Self {
            id: id.into(),
            message: message.into(),
            level,
            on_dismiss: None,
            action: None,
        }
    }

    /// Attach a single action, rendered as a button beside the message.
    ///
    /// This is what lets an error carry `[Open Settings]` or `[Retry]` rather
    /// than telling the user what went wrong and leaving them to find the fix.
    pub fn action(
        mut self,
        label: impl Into<SharedString>,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.action = Some((label.into(), Box::new(handler)));
        self
    }

    /// Attach a dismiss handler. When set, the toast renders a close button
    /// that invokes this handler on click.
    pub fn on_dismiss(
        mut self,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_dismiss = Some(Box::new(handler));
        self
    }
}

impl RenderOnce for Toast {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = cx.colors();
        let status = cx.status();

        let level_color = self.level.color();
        let icon_name = self.level.icon();

        let icon_bg = match self.level {
            ToastLevel::Success => status.success_background,
            ToastLevel::Error => status.error_background,
            ToastLevel::Warning => status.warning_background,
            ToastLevel::Info => status.info_background,
        };

        let accent = match self.level {
            ToastLevel::Success => status.success,
            ToastLevel::Error => status.error,
            ToastLevel::Warning => status.warning,
            ToastLevel::Info => status.info,
        };

        div()
            .id(self.id)
            .flex()
            .flex_row()
            .items_stretch()
            .bg(colors.elevated_surface_background)
            .border_1()
            .border_color(accent)
            .rounded(px(8.))
            .elevation_3(cx)
            .overflow_hidden()
            // Colored left accent bar so the severity is conveyed by position,
            // not color alone.
            .child(div().flex_shrink_0().w(px(3.)).bg(accent))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .h_flex()
                    .gap(px(6.))
                    .pl(px(8.))
                    .pr(px(6.))
                    .py(px(6.))
                    .child(
                        div()
                            .flex_shrink_0()
                            .p(px(3.))
                            .rounded_md()
                            .bg(icon_bg)
                            .child(
                                Icon::new(icon_name)
                                    .size(IconSize::Small)
                                    .color(level_color),
                            ),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .h_flex()
                            .gap(px(4.))
                            // A bold severity word prefix keeps the level legible
                            // without relying on color perception.
                            .child(
                                Label::new(format!("{}:", self.level.label()))
                                    .size(LabelSize::Small)
                                    .weight(FontWeight::BOLD)
                                    .color(level_color),
                            )
                            .child(
                                div().flex_1().min_w_0().child(
                                    Label::new(self.message)
                                        .size(LabelSize::Small)
                                        .color(Color::Default),
                                ),
                            ),
                    )
                    .when_some(self.action, |this, (label, on_click)| {
                        this.child(
                            crate::Button::new("toast-action", label)
                                .style(crate::ButtonStyle::Subtle)
                                .size(ButtonSize::Compact)
                                .color(level_color)
                                .on_click(on_click),
                        )
                    })
                    .when_some(self.on_dismiss, |this, on_dismiss| {
                        this.child(
                            IconButton::new("toast-dismiss", IconName::X)
                                .size(ButtonSize::Compact)
                                .color(Color::Muted)
                                .tooltip("Dismiss")
                                .on_click(on_dismiss),
                        )
                    }),
            )
    }
}
