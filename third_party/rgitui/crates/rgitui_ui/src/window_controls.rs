//! Linux window controls (minimize, maximize/restore, close).
//! Rendered only when the window uses client-side decorations (CSD) — e.g.
//! GNOME/Wayland — where the compositor does not draw the controls itself.

use crate::{Icon, IconName, IconSize};
use gpui::prelude::*;
use gpui::{div, px, App, ElementId, Hsla, RenderOnce, Styled, Window};

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Clone, Copy)]
pub enum WindowControlType {
    Minimize,
    Restore,
    Maximize,
    Close,
}

impl WindowControlType {
    pub fn icon_name(&self) -> IconName {
        match self {
            WindowControlType::Minimize => IconName::Minimize,
            WindowControlType::Restore => IconName::Restore,
            WindowControlType::Maximize => IconName::Maximize,
            WindowControlType::Close => IconName::Close,
        }
    }
}

struct WindowControlStyle {
    background_hover: Hsla,
    icon: Hsla,
}

impl WindowControlStyle {
    fn new(cx: &mut App) -> Self {
        use rgitui_theme::ActiveTheme;
        let colors = cx.colors();
        Self {
            background_hover: colors.ghost_element_hover,
            icon: colors.icon,
        }
    }
}

#[derive(IntoElement)]
pub struct WindowControl {
    id: ElementId,
    control_type: WindowControlType,
    style: WindowControlStyle,
}

impl WindowControl {
    pub fn new(id: impl Into<ElementId>, control_type: WindowControlType, cx: &mut App) -> Self {
        Self {
            id: id.into(),
            control_type,
            style: WindowControlStyle::new(cx),
        }
    }
}

impl RenderOnce for WindowControl {
    fn render(self, _window: &mut Window, _cx: &mut App) -> impl IntoElement {
        let icon = Icon::new(self.control_type.icon_name())
            .size(IconSize::XSmall)
            .color(rgitui_theme::Color::Custom(self.style.icon))
            .into_element();

        div()
            .flex()
            .flex_row()
            .id(self.id)
            .w(px(28.))
            .h(px(28.))
            .cursor_pointer()
            .content_center()
            .justify_center()
            .rounded(px(4.))
            .hover(move |s| gpui::Styled::bg(s, self.style.background_hover))
            .active(move |s| gpui::Styled::bg(s, self.style.background_hover))
            .on_click(move |_, window: &mut Window, cx: &mut App| {
                cx.stop_propagation();
                match self.control_type {
                    WindowControlType::Minimize => window.minimize_window(),
                    WindowControlType::Restore | WindowControlType::Maximize => {
                        window.zoom_window()
                    }
                    WindowControlType::Close => window.remove_window(),
                }
            })
            .child(icon)
    }
}
