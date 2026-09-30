use gpui::prelude::*;
use gpui::{div, px, App, Window};
use rgitui_theme::{ActiveTheme, Color};

/// A small colored dot indicator for showing status.
#[derive(IntoElement)]
pub struct Indicator {
    color: Color,
}

impl Indicator {
    pub fn new(color: Color) -> Self {
        Self { color }
    }

    pub fn dot(color: Color) -> Self {
        Self::new(color)
    }
}

impl RenderOnce for Indicator {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let resolved = self.color.color(cx);
        let halo = cx.colors().surface_background;

        div()
            .w(px(7.))
            .h(px(7.))
            .rounded_full()
            .bg(resolved)
            .border_1()
            .border_color(halo)
            .flex_shrink_0()
    }
}
