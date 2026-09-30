use gpui::prelude::*;
use gpui::{div, px, svg, Animation, AnimationExt, App, SharedString, Transformation, Window};
use rgitui_theme::{Color, StyledExt};
use std::time::Duration;

use crate::{Label, LabelSize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SpinnerSize {
    Small,
    #[default]
    Medium,
}

#[derive(IntoElement)]
pub struct Spinner {
    size: SpinnerSize,
    label: Option<SharedString>,
}

impl Default for Spinner {
    fn default() -> Self {
        Self::new()
    }
}

impl Spinner {
    pub fn new() -> Self {
        Self {
            size: SpinnerSize::default(),
            label: None,
        }
    }

    pub fn size(mut self, size: SpinnerSize) -> Self {
        self.size = size;
        self
    }

    pub fn label(mut self, label: impl Into<SharedString>) -> Self {
        self.label = Some(label.into());
        self
    }
}

impl RenderOnce for Spinner {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let (icon_size, label_size, gap) = match self.size {
            SpinnerSize::Small => (px(14.), LabelSize::XSmall, px(4.)),
            SpinnerSize::Medium => (px(18.), LabelSize::Small, px(6.)),
        };

        let text_color = Color::Accent.color(cx);

        let spinner_icon = svg()
            .path("icons/refresh-cw.svg")
            .size(icon_size)
            .text_color(text_color)
            .with_animation(
                "spinner-rotate",
                Animation::new(Duration::from_millis(1000)).repeat(),
                |icon, delta| {
                    icon.with_transformation(Transformation::rotate(gpui::percentage(delta)))
                },
            );

        let mut el = div().h_flex().gap(gap).items_center().child(spinner_icon);

        if let Some(label_text) = self.label {
            el = el.child(Label::new(label_text).size(label_size).color(Color::Muted));
        }

        el
    }
}
