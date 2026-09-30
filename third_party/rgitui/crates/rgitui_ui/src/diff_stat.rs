use gpui::prelude::*;
use gpui::{div, px, App, SharedString, Window};
use rgitui_theme::{ActiveTheme, Color, StyledExt};

use crate::{Label, LabelSize};

const TOTAL_BLOCKS: usize = 5;

/// A compact diff stat display showing additions/deletions with a colored bar.
///
/// Renders as: `+3 -2 [=====]` where the bar uses green for additions and red
/// for deletions, proportional to their share of total changes.
#[derive(IntoElement)]
pub struct DiffStat {
    added: usize,
    removed: usize,
}

impl DiffStat {
    pub fn new(added: usize, removed: usize) -> Self {
        Self { added, removed }
    }
}

impl RenderOnce for DiffStat {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let added_color = Color::Added.color(cx);
        let deleted_color = Color::Deleted.color(cx);
        let neutral_color = cx.colors().text_disabled;

        let total = self.added + self.removed;

        let (green_blocks, red_blocks) = if total == 0 {
            (0, 0)
        } else {
            let green = (self.added * TOTAL_BLOCKS).div_ceil(total);
            let green = green.min(TOTAL_BLOCKS);
            let red = TOTAL_BLOCKS - green;
            (green, red)
        };

        let additions_str: SharedString = format!("+{}", self.added).into();
        let deletions_str: SharedString = format!("-{}", self.removed).into();

        let mut bar = div().h_flex().gap(px(1.));

        for i in 0..TOTAL_BLOCKS {
            let color = if total == 0 {
                neutral_color
            } else if i < green_blocks {
                added_color
            } else if i < green_blocks + red_blocks {
                deleted_color
            } else {
                neutral_color
            };
            bar = bar.child(div().w(px(4.)).h(px(10.)).rounded(px(1.)).bg(color));
        }

        div()
            .h_flex()
            .gap(px(4.))
            .flex_shrink_0()
            .items_center()
            .child(
                Label::new(additions_str)
                    .size(LabelSize::XSmall)
                    .color(Color::Added),
            )
            .child(
                Label::new(deletions_str)
                    .size(LabelSize::XSmall)
                    .color(Color::Deleted),
            )
            .child(bar)
    }
}
