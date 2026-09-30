use gpui::prelude::*;
use gpui::{div, px, Animation, AnimationExt, App, ClickEvent, SharedString, Window};
use rgitui_theme::{ActiveTheme, StyledExt};
use std::time::Duration;

use crate::{Label, LabelSize};

pub struct ContextMenuItem {
    label: SharedString,
    disabled: bool,
    is_separator: bool,
    shortcut: Option<SharedString>,
    on_click: Option<crate::ClickHandler>,
}

impl ContextMenuItem {
    pub fn new(label: impl Into<SharedString>) -> Self {
        Self {
            label: label.into(),
            disabled: false,
            is_separator: false,
            shortcut: None,
            on_click: None,
        }
    }

    pub fn separator() -> Self {
        Self {
            label: "".into(),
            disabled: false,
            is_separator: true,
            shortcut: None,
            on_click: None,
        }
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    pub fn shortcut(mut self, shortcut: impl Into<SharedString>) -> Self {
        self.shortcut = Some(shortcut.into());
        self
    }

    pub fn on_click(
        mut self,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_click = Some(Box::new(handler));
        self
    }
}

// TODO(audit): UX-13 — add keyboard navigation + focus handling (FocusHandle,
// Up/Down to move a highlighted index, Enter to activate, Esc to dismiss,
// type-ahead, focus transfer on open). Deferred: large framework migration to a
// stateful component; ref Zed crates/ui/src/components/context_menu.rs.
#[derive(IntoElement)]
pub struct ContextMenu {
    items: Vec<ContextMenuItem>,
    min_width: f32,
}

impl Default for ContextMenu {
    fn default() -> Self {
        Self::new()
    }
}

impl ContextMenu {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            min_width: 180.0,
        }
    }

    pub fn item(mut self, item: ContextMenuItem) -> Self {
        self.items.push(item);
        self
    }

    pub fn separator(mut self) -> Self {
        self.items.push(ContextMenuItem::separator());
        self
    }

    pub fn min_width(mut self, width: f32) -> Self {
        self.min_width = width;
        self
    }
}

fn ease_out_quint(t: f32) -> f32 {
    1.0 - (1.0 - t).powi(5)
}

impl RenderOnce for ContextMenu {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = cx.colors();

        let mut menu = div()
            .v_flex()
            .min_w(px(self.min_width))
            .py(px(4.))
            .bg(colors.elevated_surface_background)
            .border_1()
            .border_color(colors.border)
            .rounded_md()
            .elevation_3(cx);

        for (i, item) in self.items.into_iter().enumerate() {
            if item.is_separator {
                menu = menu.child(
                    div()
                        .w_full()
                        .h(px(1.))
                        .my(px(4.))
                        .bg(colors.border_variant),
                );
                continue;
            }

            let label = item.label.clone();
            let disabled = item.disabled;

            let hover_bg = colors.ghost_element_hover;
            let active_bg = colors.ghost_element_active;
            let accent = colors.text_accent;

            let mut row = div()
                .id(gpui::ElementId::NamedInteger("ctx-item".into(), i as u64))
                .h_flex()
                .w_full()
                .h(px(28.))
                .mx(px(4.))
                .px(px(8.))
                .gap_2()
                .items_center()
                .rounded(px(4.));

            if !disabled {
                row = row
                    .hover(move |s| s.bg(hover_bg).border_l_2().border_color(accent))
                    .active(move |s| s.bg(active_bg))
                    .cursor_pointer();
            }

            if let Some(on_click) = item.on_click {
                if !disabled {
                    row = row.on_click(on_click);
                }
            }

            let text_color = if disabled {
                crate::Color::Disabled
            } else {
                crate::Color::Default
            };

            row = row.child(Label::new(label).size(LabelSize::Small).color(text_color));

            if let Some(shortcut) = item.shortcut {
                row = row.child(div().flex_1()).child(
                    Label::new(shortcut)
                        .size(LabelSize::XSmall)
                        .color(crate::Color::Muted),
                );
            }

            menu = menu.child(row);
        }

        menu.with_animation(
            "context-menu-entrance",
            Animation::new(Duration::from_millis(100)).with_easing(ease_out_quint),
            |el, delta| el.opacity(delta),
        )
    }
}
