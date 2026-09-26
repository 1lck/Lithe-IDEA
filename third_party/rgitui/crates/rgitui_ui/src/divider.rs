use gpui::prelude::*;
use gpui::{div, px, App, Window};
use rgitui_theme::ActiveTheme;

/// A horizontal divider line.
#[derive(IntoElement)]
pub struct Divider;

impl Default for Divider {
    fn default() -> Self {
        Self::new()
    }
}

impl Divider {
    pub fn new() -> Self {
        Self
    }
}

impl RenderOnce for Divider {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let border_color = cx.colors().border_variant;
        div().w_full().h(px(1.)).bg(border_color)
    }
}

/// A vertical divider line.
#[derive(IntoElement)]
pub struct VerticalDivider;

impl Default for VerticalDivider {
    fn default() -> Self {
        Self::new()
    }
}

impl VerticalDivider {
    pub fn new() -> Self {
        Self
    }
}

impl RenderOnce for VerticalDivider {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let border_color = cx.colors().border_variant;
        div()
            .h(px(16.))
            .w(px(1.))
            .mx(px(4.))
            .bg(border_color)
            .flex_shrink_0()
    }
}
