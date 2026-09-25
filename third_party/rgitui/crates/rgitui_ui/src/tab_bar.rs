use gpui::prelude::*;
use gpui::{div, px, AnyElement, App, ClickEvent, CursorStyle, ElementId, SharedString, Window};
use rgitui_theme::{ActiveTheme, Color, StyledExt};
use smallvec::SmallVec;

use crate::{IconButton, IconName, Label, LabelSize};

/// A single tab in a tab bar.
#[derive(IntoElement)]
pub struct Tab {
    id: ElementId,
    label: SharedString,
    active: bool,
    dirty: bool,
    closeable: bool,
    on_click: Option<crate::ClickHandler>,
    on_close: Option<crate::ClickHandler>,
}

impl Tab {
    pub fn new(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            active: false,
            dirty: false,
            closeable: true,
            on_click: None,
            on_close: None,
        }
    }

    pub fn active(mut self, active: bool) -> Self {
        self.active = active;
        self
    }

    pub fn dirty(mut self, dirty: bool) -> Self {
        self.dirty = dirty;
        self
    }

    pub fn closeable(mut self, closeable: bool) -> Self {
        self.closeable = closeable;
        self
    }

    pub fn on_click(
        mut self,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_click = Some(Box::new(handler));
        self
    }

    pub fn on_close(
        mut self,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_close = Some(Box::new(handler));
        self
    }
}

impl RenderOnce for Tab {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = cx.colors();
        let bg = if self.active {
            colors.tab_active_background
        } else {
            colors.tab_inactive_background
        };

        let label_color = if self.active {
            Color::Default
        } else {
            Color::Muted
        };

        let active_bg = colors.ghost_element_active;

        let mut tab = div()
            .id(self.id.clone())
            .group("tab")
            .h_flex()
            .h(px(28.))
            .px_2()
            .gap_1()
            .bg(bg)
            .cursor(CursorStyle::PointingHand)
            .hover(|s| s.bg(colors.ghost_element_hover))
            .active(move |s| s.bg(active_bg));

        if self.active {
            tab = tab.border_b_2().border_color(colors.text_accent);
        }

        if let Some(on_click) = self.on_click {
            tab = tab.on_click(on_click);
        }

        // Dirty indicator
        if self.dirty {
            tab = tab.child(
                div()
                    .w(px(6.))
                    .h(px(6.))
                    .rounded_full()
                    .bg(colors.text_accent),
            );
        }

        tab = tab.child(
            Label::new(self.label)
                .size(LabelSize::Small)
                .color(label_color)
                .truncate(),
        );

        // Close button (visible on hover or when active)
        if self.closeable {
            let is_active = self.active;
            let mut close_btn = IconButton::new(
                ElementId::Name(format!("{}-close", self.id).into()),
                IconName::X,
            )
            .size(crate::ButtonSize::Compact)
            .color(Color::Muted);

            if let Some(on_close) = self.on_close {
                close_btn = close_btn.on_click(move |event, window, cx| {
                    // Prevent the click from bubbling to the tab row, which would
                    // otherwise activate the tab on the same gesture that closes it.
                    cx.stop_propagation();
                    on_close(event, window, cx);
                });
            }

            // Only show close button on hover or when tab is active
            tab = tab.child(
                div()
                    .when(!is_active, |el| {
                        el.invisible().group_hover("tab", |s| s.visible())
                    })
                    .child(close_btn),
            );
        }

        tab
    }
}

/// A horizontal tab bar containing multiple tabs.
#[derive(IntoElement)]
pub struct TabBar {
    tabs: SmallVec<[AnyElement; 4]>,
    end_slot: Option<AnyElement>,
}

impl Default for TabBar {
    fn default() -> Self {
        Self::new()
    }
}

impl TabBar {
    pub fn new() -> Self {
        Self {
            tabs: SmallVec::new(),
            end_slot: None,
        }
    }

    pub fn tab(mut self, tab: impl IntoElement) -> Self {
        self.tabs.push(tab.into_any_element());
        self
    }

    pub fn end_slot(mut self, slot: impl IntoElement) -> Self {
        self.end_slot = Some(slot.into_any_element());
        self
    }
}

impl RenderOnce for TabBar {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = cx.colors();

        let mut bar = div()
            .h_flex()
            .w_full()
            .h(px(30.))
            .bg(colors.tab_bar_background)
            .border_b_1()
            .border_color(colors.border_variant)
            .overflow_x_hidden();

        // Scrollable tab area
        let mut tab_area = div().h_flex().flex_1().min_w_0();
        for tab in self.tabs {
            tab_area = tab_area.child(tab);
        }
        bar = bar.child(tab_area);

        // End slot (e.g., + button)
        if let Some(end) = self.end_slot {
            bar = bar.child(div().h_flex().px_1().child(end));
        }

        bar
    }
}
