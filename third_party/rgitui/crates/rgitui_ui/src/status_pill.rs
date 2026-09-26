use gpui::prelude::*;
use gpui::{div, px, App, ClickEvent, ElementId, FontWeight, SharedString, Window};
use rgitui_theme::Color;

use crate::{
    Button, ButtonSize, ButtonStyle, ClickHandler, Icon, IconName, IconSize, Label, LabelSize,
};

/// Whether a credential has been configured and, if so, whether it works.
///
/// Nothing in the app previously distinguished "a key is present" from "a key
/// that works" — `has_api_key` was `!trim().is_empty()`, so a typo looked
/// identical to a working key until the user staged, clicked, waited, and got
/// a red toast.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionState {
    Unconfigured,
    Testing,
    Connected,
    Failed,
}

impl ConnectionState {
    pub fn icon(self) -> IconName {
        match self {
            ConnectionState::Unconfigured => IconName::DotOutline,
            ConnectionState::Testing => IconName::HalfCircle,
            ConnectionState::Connected => IconName::CheckCircle,
            ConnectionState::Failed => IconName::XCircle,
        }
    }

    pub fn color(self) -> Color {
        match self {
            ConnectionState::Unconfigured => Color::Muted,
            ConnectionState::Testing => Color::Accent,
            ConnectionState::Connected => Color::Success,
            ConnectionState::Failed => Color::Error,
        }
    }

    /// The default label, used when the caller does not supply its own.
    pub fn default_label(self) -> &'static str {
        match self {
            ConnectionState::Unconfigured => "No key",
            ConnectionState::Testing => "Testing",
            ConnectionState::Connected => "Connected",
            ConnectionState::Failed => "Failed",
        }
    }
}

/// A compact connection-status indicator: an icon, a label, an optional
/// second line of detail, and an optional action.
///
/// The icon differs per state as well as the color, so the status is legible
/// without relying on color perception.
#[derive(IntoElement)]
pub struct StatusPill {
    id: ElementId,
    state: ConnectionState,
    label: SharedString,
    detail: Option<SharedString>,
    action: Option<(SharedString, ClickHandler)>,
}

impl StatusPill {
    pub fn new(
        id: impl Into<ElementId>,
        state: ConnectionState,
        label: impl Into<SharedString>,
    ) -> Self {
        Self {
            id: id.into(),
            state,
            label: label.into(),
            detail: None,
            action: None,
        }
    }

    /// Build a pill with the state's own wording.
    pub fn for_state(id: impl Into<ElementId>, state: ConnectionState) -> Self {
        Self::new(id, state, state.default_label())
    }

    pub fn detail(mut self, detail: impl Into<SharedString>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    pub fn action(
        mut self,
        label: impl Into<SharedString>,
        on_click: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.action = Some((label.into(), Box::new(on_click)));
        self
    }
}

impl RenderOnce for StatusPill {
    fn render(self, _window: &mut Window, _cx: &mut App) -> impl IntoElement {
        let color = self.state.color();
        let has_detail = self.detail.is_some();

        div()
            .id(self.id)
            .flex()
            .flex_row()
            .gap(px(6.))
            // Top-aligned rather than centred: once the detail line wraps,
            // centring would drift the icon away from the label it belongs to.
            .items_start()
            .child(
                div()
                    .flex_shrink_0()
                    // Nudge the icon onto the label's baseline.
                    .pt(px(1.))
                    .child(
                        Icon::new(self.state.icon())
                            .size(IconSize::Small)
                            .color(color),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .gap(px(1.))
                    .child(
                        Label::new(self.label)
                            .size(LabelSize::Small)
                            .weight(FontWeight::MEDIUM)
                            .color(color),
                    )
                    .when_some(self.detail, |this, detail| {
                        this.child(
                            Label::new(detail)
                                .size(LabelSize::XSmall)
                                .color(Color::Muted),
                        )
                    }),
            )
            .when_some(self.action, |this, (label, on_click)| {
                this.child(
                    div().flex_shrink_0().child(
                        Button::new("status-pill-action", label)
                            .style(ButtonStyle::Subtle)
                            .size(ButtonSize::Compact)
                            .color(color)
                            .on_click(on_click),
                    ),
                )
            })
            .when(has_detail, |this| this.min_h(px(30.)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_state_has_a_distinct_icon_so_it_reads_without_colour() {
        let states = [
            ConnectionState::Unconfigured,
            ConnectionState::Testing,
            ConnectionState::Connected,
            ConnectionState::Failed,
        ];
        let mut icons: Vec<IconName> = states.iter().map(|state| state.icon()).collect();
        icons.sort_by_key(|icon| format!("{icon:?}"));
        icons.dedup();
        assert_eq!(icons.len(), states.len());
    }

    #[test]
    fn every_state_has_a_distinct_colour_and_label() {
        let states = [
            ConnectionState::Unconfigured,
            ConnectionState::Testing,
            ConnectionState::Connected,
            ConnectionState::Failed,
        ];
        let mut colors: Vec<String> = states
            .iter()
            .map(|state| format!("{:?}", state.color()))
            .collect();
        colors.sort();
        colors.dedup();
        assert_eq!(colors.len(), states.len());

        for state in states {
            assert!(!state.default_label().is_empty());
        }
    }

    #[test]
    fn a_failed_connection_is_not_rendered_in_the_success_colour() {
        assert_eq!(ConnectionState::Failed.color(), Color::Error);
        assert_eq!(ConnectionState::Connected.color(), Color::Success);
        assert_eq!(ConnectionState::Unconfigured.color(), Color::Muted);
    }
}
