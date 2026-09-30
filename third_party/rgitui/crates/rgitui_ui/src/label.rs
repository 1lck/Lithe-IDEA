use gpui::prelude::*;
use gpui::{div, App, SharedString, Window};
use rgitui_theme::Color;

/// Label sizes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LabelSize {
    XSmall,
    Small,
    #[default]
    Default,
    Large,
}

/// A text label with semantic color and size support.
#[derive(IntoElement)]
pub struct Label {
    text: SharedString,
    color: Color,
    size: LabelSize,
    weight: Option<gpui::FontWeight>,
    strikethrough: bool,
    italic: bool,
    truncate: bool,
}

impl Label {
    pub fn new(text: impl Into<SharedString>) -> Self {
        Self {
            text: text.into(),
            color: Color::Default,
            size: LabelSize::Default,
            weight: None,
            strikethrough: false,
            italic: false,
            truncate: false,
        }
    }

    pub fn color(mut self, color: Color) -> Self {
        self.color = color;
        self
    }

    pub fn size(mut self, size: LabelSize) -> Self {
        self.size = size;
        self
    }

    pub fn weight(mut self, weight: gpui::FontWeight) -> Self {
        self.weight = Some(weight);
        self
    }

    pub fn strikethrough(mut self) -> Self {
        self.strikethrough = true;
        self
    }

    pub fn italic(mut self) -> Self {
        self.italic = true;
        self
    }

    pub fn truncate(mut self) -> Self {
        self.truncate = true;
        self
    }
}

impl RenderOnce for Label {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let text_color = self.color.color(cx);

        let mut el = div().text_color(text_color);

        el = match self.size {
            LabelSize::XSmall => el.text_xs(),
            LabelSize::Small => el.text_sm(),
            LabelSize::Default => el,
            LabelSize::Large => el.text_lg(),
        };

        if let Some(weight) = self.weight {
            el = el.font_weight(weight);
        }

        if self.italic {
            el = el.italic();
        }

        if self.strikethrough {
            el = el.line_through();
        }

        if self.truncate {
            el = el
                .min_w_0()
                .overflow_x_hidden()
                .whitespace_nowrap()
                .text_ellipsis();
        }

        el.child(self.text)
    }
}
