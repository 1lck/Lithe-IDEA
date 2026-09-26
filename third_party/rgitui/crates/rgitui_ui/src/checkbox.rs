use std::rc::Rc;

use gpui::prelude::*;
use gpui::{
    div, px, App, ClickEvent, CursorStyle, ElementId, FocusHandle, KeyDownEvent, SharedString,
    Window,
};
use rgitui_theme::ActiveTheme;

use crate::{Icon, IconName, IconSize, Label, LabelSize};

/// A checkbox with checked/unchecked/indeterminate states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckState {
    Unchecked,
    Checked,
    Indeterminate,
}

/// Event-agnostic toggle callback shared between pointer and keyboard activation.
type ToggleHandler = Rc<dyn Fn(&mut Window, &mut App)>;

#[derive(IntoElement)]
pub struct Checkbox {
    id: ElementId,
    state: CheckState,
    disabled: bool,
    label: Option<SharedString>,
    focus_handle: Option<FocusHandle>,
    on_click: Option<crate::ClickHandler>,
    on_toggle: Option<ToggleHandler>,
}

impl Checkbox {
    pub fn new(id: impl Into<ElementId>, state: CheckState) -> Self {
        Self {
            id: id.into(),
            state,
            disabled: false,
            label: None,
            focus_handle: None,
            on_click: None,
            on_toggle: None,
        }
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    /// Render an accessible label beside the box. The full row becomes the
    /// clickable hit target with padding to exceed the minimum touch size.
    pub fn label(mut self, label: impl Into<SharedString>) -> Self {
        self.label = Some(label.into());
        self
    }

    /// Provide a focus handle so the checkbox can receive keyboard focus and
    /// toggle on Space/Enter. The handle is owned by the parent view; supply it
    /// via `cx.focus_handle()` and pair it with [`Checkbox::on_toggle`].
    pub fn focus_handle(mut self, handle: FocusHandle) -> Self {
        self.focus_handle = Some(handle);
        self
    }

    pub fn on_click(
        mut self,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_click = Some(Box::new(handler));
        self
    }

    /// Set an event-agnostic toggle handler invoked by both pointer clicks on
    /// the labeled row and keyboard activation (Space/Enter) while focused.
    pub fn on_toggle(mut self, handler: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        self.on_toggle = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for Checkbox {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = cx.colors();

        let (bg, border, icon) = match self.state {
            CheckState::Checked => (
                colors.text_accent,
                colors.text_accent,
                Some(IconName::Check),
            ),
            CheckState::Indeterminate => (
                colors.text_accent,
                colors.text_accent,
                Some(IconName::Minus),
            ),
            CheckState::Unchecked => (colors.element_background, colors.border, None),
        };

        let hover_bg = colors.ghost_element_hover;
        let active_bg = colors.ghost_element_active;

        let mut box_el = div()
            .flex()
            .items_center()
            .justify_center()
            .w(px(16.))
            .h(px(16.))
            .rounded(px(3.))
            .bg(bg)
            .border_1()
            .border_color(border);

        if let Some(icon_name) = icon {
            box_el = box_el.child(Icon::new(icon_name).size(IconSize::XSmall).color(
                rgitui_theme::Color::Custom(colors.elevated_surface_background),
            ));
        }

        // Labeled variant: the whole row is the hit target, padded to exceed the
        // ~24px accessible minimum, and keyboard-toggleable when focused.
        if let Some(label) = self.label {
            let mut row = div()
                .id(self.id)
                .flex()
                .items_center()
                .gap_2()
                .px(px(6.))
                .py(px(4.))
                .rounded(px(4.))
                .child(box_el)
                .child(Label::new(label).size(LabelSize::Small));

            if self.disabled {
                row = row.opacity(0.5);
            } else {
                row = row
                    .cursor(CursorStyle::PointingHand)
                    .hover(move |s| s.bg(hover_bg))
                    .active(move |s| s.bg(active_bg));

                let on_toggle = self.on_toggle;

                if let Some(handle) = self.focus_handle {
                    row = row.track_focus(&handle);
                    if let Some(toggle) = on_toggle.clone() {
                        row = row.on_key_down(move |event: &KeyDownEvent, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "space" | "enter") {
                                toggle(window, cx);
                            }
                        });
                    }
                }

                if let Some(toggle) = on_toggle {
                    row = row.on_click(move |_event, window, cx| toggle(window, cx));
                } else if let Some(on_click) = self.on_click {
                    row = row.on_click(on_click);
                }
            }

            return row.into_any_element();
        }

        // Bare variant: kept visually identical (16x16, no padding) so existing
        // inline usages retain their layout.
        let mut container = box_el.id(self.id);

        if self.disabled {
            container = container.opacity(0.5);
        } else {
            container = container
                .cursor(CursorStyle::PointingHand)
                .hover(move |s| s.bg(hover_bg))
                .active(move |s| s.bg(active_bg));

            if let Some(on_click) = self.on_click {
                container = container.on_click(on_click);
            }
        }

        container.into_any_element()
    }
}
