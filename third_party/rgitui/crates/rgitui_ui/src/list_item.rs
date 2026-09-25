use gpui::prelude::*;
use gpui::{div, px, rems, AnyElement, App, ClickEvent, CursorStyle, ElementId, Window};
use rgitui_theme::{ActiveTheme, StyledExt};
use smallvec::SmallVec;

/// List item spacing modes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ListItemSpacing {
    ExtraDense,
    Dense,
    #[default]
    Default,
    Sparse,
}

impl ListItemSpacing {
    pub fn height(&self) -> gpui::Rems {
        match self {
            ListItemSpacing::ExtraDense => gpui::rems(1.25),
            ListItemSpacing::Dense => gpui::rems(1.5),
            ListItemSpacing::Default => gpui::rems(1.75),
            ListItemSpacing::Sparse => gpui::rems(2.0),
        }
    }
}

/// A rich list row with start/end slots, indentation, and selection state.
#[derive(IntoElement)]
pub struct ListItem {
    id: ElementId,
    disabled: bool,
    selected: bool,
    spacing: ListItemSpacing,
    density: f32,
    indent_level: usize,
    indent_step: f32,
    start_slot: Option<AnyElement>,
    end_slot: Option<AnyElement>,
    end_hover_slot: Option<AnyElement>,
    children: SmallVec<[AnyElement; 2]>,
    on_click: Option<crate::ClickHandler>,
}

impl ListItem {
    pub fn new(id: impl Into<ElementId>) -> Self {
        Self {
            id: id.into(),
            disabled: false,
            selected: false,
            spacing: ListItemSpacing::Default,
            density: 1.0,
            indent_level: 0,
            indent_step: 12.0,
            start_slot: None,
            end_slot: None,
            end_hover_slot: None,
            children: SmallVec::new(),
            on_click: None,
        }
    }

    pub fn spacing(mut self, spacing: ListItemSpacing) -> Self {
        self.spacing = spacing;
        self
    }

    /// Scales the row height by a density multiplier (e.g. a compactness
    /// setting resolved by the caller). Defaults to `1.0`.
    pub fn density(mut self, density: f32) -> Self {
        self.density = density;
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    pub fn selected(mut self, selected: bool) -> Self {
        self.selected = selected;
        self
    }

    pub fn indent_level(mut self, level: usize) -> Self {
        self.indent_level = level;
        self
    }

    pub fn start_slot(mut self, slot: impl IntoElement) -> Self {
        self.start_slot = Some(slot.into_any_element());
        self
    }

    pub fn end_slot(mut self, slot: impl IntoElement) -> Self {
        self.end_slot = Some(slot.into_any_element());
        self
    }

    pub fn end_hover_slot(mut self, slot: impl IntoElement) -> Self {
        self.end_hover_slot = Some(slot.into_any_element());
        self
    }

    pub fn child(mut self, child: impl IntoElement) -> Self {
        self.children.push(child.into_any_element());
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

impl RenderOnce for ListItem {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = cx.colors();
        let base_height = self.spacing.height();
        let height = rems(base_height.0 * self.density);
        let indent_px = self.indent_level as f32 * self.indent_step;

        let bg = if self.selected {
            colors.element_selected
        } else {
            colors.ghost_element_background
        };

        let border_color = if self.selected {
            colors.border_focused
        } else {
            colors.border_transparent
        };

        let mut row = div()
            .id(self.id)
            .group("list-item")
            .h_flex()
            .h(height)
            .w_full()
            .px_2()
            .gap_1()
            .rounded_md()
            .bg(bg)
            .border_1()
            .border_color(border_color);

        if indent_px > 0.0 {
            row = row.pl(px(indent_px + 8.0));
        }

        if !self.disabled {
            row = row
                .cursor(CursorStyle::PointingHand)
                .hover(|s| s.bg(colors.ghost_element_hover))
                .active(|s| s.bg(colors.ghost_element_active));
        }

        if let Some(on_click) = self.on_click {
            if !self.disabled {
                row = row.on_click(on_click);
            }
        }

        // Start slot
        if let Some(start) = self.start_slot {
            row = row.child(start);
        }

        // Main content (takes remaining space)
        let mut content = div().h_flex().flex_1().min_w_0().gap_1();
        for child in self.children {
            content = content.child(child);
        }
        row = row.child(content);

        // End slot (always visible)
        if let Some(end) = self.end_slot {
            row = row.child(div().h_flex().child(end));
        }

        // End hover slot (visible only on hover)
        if let Some(end_hover) = self.end_hover_slot {
            row = row.child(
                div()
                    .h_flex()
                    .invisible()
                    .group_hover("list-item", |s| s.visible())
                    .child(end_hover),
            );
        }

        row
    }
}
