use gpui::prelude::*;
use gpui::{div, px, App, ElementId, MouseButton, SharedString, StyleRefinement, Window};
use rgitui_theme::{ActiveTheme, Color, StyledExt};

use crate::{ClickHandler, Icon, IconName, IconSize, Label, LabelSize};

/// A reusable disclosure (collapsible section header) component.
///
/// Shows a chevron icon indicating expanded/collapsed state, a label,
/// and triggers a callback when clicked. The parent manages the open/closed state.
///
/// The header is a tab stop: it can be focused with the keyboard and toggled
/// with Enter or Space, and shows a focus ring when reached via the keyboard.
#[derive(IntoElement)]
pub struct Disclosure {
    id: ElementId,
    is_open: bool,
    label: SharedString,
    tab_index: isize,
    on_toggle: Option<ClickHandler>,
}

impl Disclosure {
    pub fn new(id: impl Into<ElementId>, label: impl Into<SharedString>, is_open: bool) -> Self {
        Self {
            id: id.into(),
            is_open,
            label: label.into(),
            tab_index: 0,
            on_toggle: None,
        }
    }

    /// Sets the keyboard tab order for the header. Defaults to `0`.
    pub fn tab_index(mut self, tab_index: isize) -> Self {
        self.tab_index = tab_index;
        self
    }

    pub fn on_toggle(
        mut self,
        handler: impl Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_toggle = Some(Box::new(handler));
        self
    }
}

impl RenderOnce for Disclosure {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = cx.colors();
        let hover_bg = colors.ghost_element_hover;
        let active_bg = colors.ghost_element_active;
        let focus_color = colors.border_focused;

        let chevron = if self.is_open {
            IconName::ChevronDown
        } else {
            IconName::ChevronRight
        };

        let mut row = div()
            .id(self.id)
            .h_flex()
            .gap(px(4.))
            .items_center()
            .cursor_pointer()
            .tab_index(self.tab_index)
            .rounded_sm()
            .border_1()
            .border_color(gpui::transparent_black())
            .hover(move |s| s.bg(hover_bg))
            .active(move |s| s.bg(active_bg))
            .focus_visible(move |s: StyleRefinement| s.border_color(focus_color))
            .child(
                Icon::new(chevron)
                    .size(IconSize::XSmall)
                    .color(Color::Muted),
            )
            .child(
                Label::new(self.label)
                    .size(LabelSize::XSmall)
                    .weight(gpui::FontWeight::SEMIBOLD)
                    .color(Color::Muted),
            );

        if let Some(handler) = self.on_toggle {
            // GPUI dispatches `on_click` for Enter/Space while the element is focused,
            // so this also serves as the keyboard toggle.
            row = row
                .on_mouse_down(MouseButton::Left, |_, window, _| window.prevent_default())
                .on_click(move |event, window, cx| handler(event, window, cx));
        }

        row
    }
}
