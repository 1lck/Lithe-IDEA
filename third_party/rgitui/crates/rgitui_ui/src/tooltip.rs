use gpui::prelude::*;
use gpui::{div, px, AnyView, App, Context, SharedString, Window};
use rgitui_theme::{ActiveTheme, Color, StyledExt};

use crate::Label;

/// Factory for creating tooltip closures suitable for GPUI's `.tooltip()` API.
pub struct Tooltip;

impl Tooltip {
    /// Create a tooltip closure suitable for GPUI's `.tooltip()` method.
    /// Returns a closure that constructs a `TooltipView` as an `AnyView`.
    pub fn text(text: impl Into<SharedString>) -> impl Fn(&mut Window, &mut App) -> AnyView {
        let text: SharedString = text.into();
        move |_window: &mut Window, cx: &mut App| {
            let t = text.clone();
            cx.new(move |_cx: &mut Context<TooltipView>| TooltipView {
                text: t,
                shortcut: None,
            })
            .into()
        }
    }

    /// Create a tooltip with a keyboard shortcut hint.
    pub fn with_shortcut(
        text: impl Into<SharedString>,
        shortcut: impl Into<SharedString>,
    ) -> impl Fn(&mut Window, &mut App) -> AnyView {
        let text: SharedString = text.into();
        let shortcut: SharedString = shortcut.into();
        move |_window: &mut Window, cx: &mut App| {
            let t = text.clone();
            let s = shortcut.clone();
            cx.new(move |_cx: &mut Context<TooltipView>| TooltipView {
                text: t,
                shortcut: Some(s),
            })
            .into()
        }
    }
}

/// A tooltip view for use with GPUI's `.tooltip()` API.
pub struct TooltipView {
    text: SharedString,
    shortcut: Option<SharedString>,
}

impl Render for TooltipView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let colors = cx.colors();
        let mut row = div()
            .h_flex()
            .gap(px(6.))
            .items_center()
            .px_2()
            .py_1()
            .bg(colors.elevated_surface_background)
            .border_1()
            .border_color(colors.border)
            .rounded(px(6.))
            .elevation_2(cx)
            .child(
                Label::new(self.text.clone())
                    .size(crate::LabelSize::Small)
                    .color(Color::Default),
            );

        if let Some(ref shortcut) = self.shortcut {
            row = row.child(
                div()
                    .h_flex()
                    .h(px(16.))
                    .px(px(4.))
                    .rounded(px(3.))
                    .bg(colors.ghost_element_hover)
                    .items_center()
                    .child(
                        Label::new(shortcut.clone())
                            .size(crate::LabelSize::XSmall)
                            .color(Color::Muted),
                    ),
            );
        }

        row
    }
}
