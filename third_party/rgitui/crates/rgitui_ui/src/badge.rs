use gpui::prelude::*;
use gpui::{div, px, App, Hsla, SharedString, Window};
use rgitui_theme::{Color, StyledExt};

use crate::{Label, LabelSize};

/// A small badge/chip for displaying tags, status labels, branch names, etc.
#[derive(IntoElement)]
pub struct Badge {
    text: SharedString,
    color: Color,
    italic: bool,
    bold: bool,
    prefix: Option<SharedString>,
    compact: bool,
}

impl Badge {
    pub fn new(text: impl Into<SharedString>) -> Self {
        Self {
            text: text.into(),
            color: Color::Accent,
            italic: false,
            bold: false,
            prefix: None,
            compact: false,
        }
    }

    pub fn color(mut self, color: Color) -> Self {
        self.color = color;
        self
    }

    pub fn italic(mut self) -> Self {
        self.italic = true;
        self
    }

    pub fn bold(mut self) -> Self {
        self.bold = true;
        self
    }

    pub fn prefix(mut self, prefix: impl Into<SharedString>) -> Self {
        self.prefix = Some(prefix.into());
        self
    }

    /// Reduce chip height and horizontal padding for dense ref-label rows.
    pub fn compact(mut self) -> Self {
        self.compact = true;
        self
    }
}

impl RenderOnce for Badge {
    fn render(self, _window: &mut Window, _cx: &mut App) -> impl IntoElement {
        let text_color = self.color.color(_cx);
        let bg = Hsla {
            a: 0.15,
            ..text_color
        };
        let border = Hsla {
            a: 0.3,
            ..text_color
        };

        let weight = if self.bold {
            gpui::FontWeight::BOLD
        } else {
            gpui::FontWeight::SEMIBOLD
        };

        let mut label = Label::new(self.text)
            .size(LabelSize::XSmall)
            .weight(weight)
            .color(self.color)
            .truncate();

        if self.italic {
            label = label.italic();
        }

        let container = div()
            .h_flex()
            .gap(px(2.))
            .px(if self.compact { px(5.) } else { px(6.) })
            .py(px(1.))
            .h(if self.compact { px(18.) } else { px(20.) })
            .items_center()
            .rounded(if self.compact { px(9.) } else { px(10.) })
            .bg(bg)
            .border_1()
            .border_color(border)
            .overflow_x_hidden();

        let container = if let Some(prefix_text) = self.prefix {
            container.child(
                Label::new(prefix_text)
                    .size(LabelSize::XSmall)
                    .color(self.color),
            )
        } else {
            container
        };

        container.child(label)
    }
}
