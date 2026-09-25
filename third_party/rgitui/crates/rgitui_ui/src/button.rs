use gpui::prelude::*;
use gpui::{
    div, px, AnyElement, AnyView, App, ClickEvent, CursorStyle, ElementId, Hsla, MouseButton,
    SharedString, StyleRefinement, Window,
};
use rgitui_theme::{ActiveTheme, Color, StyledExt};

use crate::{Icon, IconName, IconSize, Label, LabelSize, Tooltip};

/// A tooltip factory closure matching GPUI's native `.tooltip()` signature.
type TooltipBuilder = Box<dyn Fn(&mut Window, &mut App) -> AnyView + 'static>;

/// Button visual styles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ButtonStyle {
    /// Solid background color.
    Filled,
    /// Default: transparent, shows bg on hover.
    #[default]
    Subtle,
    /// Border + semi-transparent background.
    Outlined,
    /// Semantic tinted button.
    Tinted(TintColor),
    /// Fully transparent, only text color changes.
    Transparent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TintColor {
    Accent,
    Error,
    Warning,
    Success,
}

/// Button sizes controlling height.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ButtonSize {
    Large,
    #[default]
    Default,
    Compact,
    None,
}

impl ButtonSize {
    pub fn height(&self) -> gpui::Rems {
        match self {
            ButtonSize::Large => gpui::rems(2.0),     // 32px
            ButtonSize::Default => gpui::rems(1.75),  // 28px
            ButtonSize::Compact => gpui::rems(1.375), // 22px
            ButtonSize::None => gpui::rems(1.0),      // 16px
        }
    }

    fn icon_size(&self) -> IconSize {
        match self {
            ButtonSize::Large => IconSize::Medium,
            ButtonSize::Default => IconSize::Small,
            ButtonSize::Compact => IconSize::XSmall,
            ButtonSize::None => IconSize::XSmall,
        }
    }

    fn label_size(&self) -> LabelSize {
        match self {
            ButtonSize::Large => LabelSize::Default,
            ButtonSize::Default => LabelSize::Small,
            ButtonSize::Compact => LabelSize::XSmall,
            ButtonSize::None => LabelSize::XSmall,
        }
    }
}

/// Resolved background, hover, active, and border colors for a button style.
struct ResolvedColors {
    background: Option<Hsla>,
    hover: Option<Hsla>,
    active: Option<Hsla>,
    border: Option<Hsla>,
}

impl ButtonStyle {
    fn colors(self, cx: &App) -> ResolvedColors {
        let colors = cx.colors();
        match self {
            ButtonStyle::Filled => ResolvedColors {
                background: Some(colors.element_background),
                hover: Some(colors.element_hover),
                active: Some(colors.element_active),
                border: None,
            },
            ButtonStyle::Subtle => ResolvedColors {
                background: None,
                hover: Some(colors.ghost_element_hover),
                active: Some(colors.ghost_element_active),
                border: None,
            },
            ButtonStyle::Outlined => ResolvedColors {
                background: Some(colors.element_background),
                hover: Some(colors.element_hover),
                active: Some(colors.element_active),
                border: Some(colors.border),
            },
            ButtonStyle::Tinted(tint) => {
                let status = cx.status();
                let bg_color = match tint {
                    TintColor::Accent => status.info_background,
                    TintColor::Error => status.error_background,
                    TintColor::Warning => status.warning_background,
                    TintColor::Success => status.success_background,
                };
                ResolvedColors {
                    background: Some(bg_color),
                    hover: Some(Hsla {
                        a: (bg_color.a + 0.1).min(1.0),
                        ..bg_color
                    }),
                    active: Some(Hsla {
                        a: (bg_color.a + 0.2).min(1.0),
                        ..bg_color
                    }),
                    border: None,
                }
            }
            ButtonStyle::Transparent => ResolvedColors {
                background: None,
                hover: Some(colors.ghost_element_hover),
                active: Some(colors.ghost_element_active),
                border: None,
            },
        }
    }

    /// Whether this style paints a solid (non-ghost) surface. Solid styles swap to
    /// dedicated disabled colors; ghost styles dim with reduced opacity instead.
    fn is_solid(self) -> bool {
        matches!(
            self,
            ButtonStyle::Filled | ButtonStyle::Outlined | ButtonStyle::Tinted(_)
        )
    }
}

/// Shared base for [`Button`] and [`IconButton`].
///
/// Owns the single style, state, cursor, focus, and click-handling path so both
/// public components resolve appearance and behavior identically. Callers build a
/// `ButtonLike`, push their content as children, and render it.
#[derive(IntoElement)]
struct ButtonLike {
    id: ElementId,
    style: ButtonStyle,
    size: ButtonSize,
    disabled: bool,
    full_width: bool,
    fixed_size: bool,
    tab_index: isize,
    tooltip: Option<TooltipBuilder>,
    on_click: Option<crate::ClickHandler>,
    children: Vec<AnyElement>,
}

impl ButtonLike {
    fn new(id: impl Into<ElementId>) -> Self {
        Self {
            id: id.into(),
            style: ButtonStyle::default(),
            size: ButtonSize::default(),
            disabled: false,
            full_width: false,
            fixed_size: false,
            tab_index: 0,
            tooltip: None,
            on_click: None,
            children: Vec::new(),
        }
    }

    fn style(mut self, style: ButtonStyle) -> Self {
        self.style = style;
        self
    }

    fn size(mut self, size: ButtonSize) -> Self {
        self.size = size;
        self
    }

    fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    fn full_width(mut self, full_width: bool) -> Self {
        self.full_width = full_width;
        self
    }

    /// Render as a square button sized to [`ButtonSize::height`] on both axes.
    fn fixed_size(mut self, fixed_size: bool) -> Self {
        self.fixed_size = fixed_size;
        self
    }

    fn tab_index(mut self, tab_index: isize) -> Self {
        self.tab_index = tab_index;
        self
    }

    fn tooltip(mut self, tooltip: TooltipBuilder) -> Self {
        self.tooltip = Some(tooltip);
        self
    }

    fn on_click(mut self, on_click: Option<crate::ClickHandler>) -> Self {
        self.on_click = on_click;
        self
    }
}

impl ParentElement for ButtonLike {
    fn extend(&mut self, elements: impl IntoIterator<Item = AnyElement>) {
        self.children.extend(elements);
    }
}

impl RenderOnce for ButtonLike {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = cx.colors();
        let resolved = self.style.colors(cx);

        let height = self.size.height();
        let padding = match self.size {
            ButtonSize::Large => px(12.),
            ButtonSize::Default => px(8.),
            ButtonSize::Compact => px(6.),
            ButtonSize::None => px(4.),
        };

        let mut container = div().id(self.id).h_flex().h(height).rounded_md();

        // Disabled controls are conventionally removed from the keyboard tab order.
        if !self.disabled {
            container = container.tab_index(self.tab_index);
        }

        if self.fixed_size {
            container = container.w(height).justify_center();
        } else {
            container = container.px(padding).gap_1();
        }

        if self.full_width {
            container = container.w_full().justify_center();
        }

        if self.disabled {
            // Disabled affordance: dim or swap to dedicated disabled surface colors,
            // and show the not-allowed cursor instead of the pointing hand.
            if self.style.is_solid() {
                container = container
                    .bg(colors.element_disabled)
                    .text_color(colors.text_disabled);
                if resolved.border.is_some() {
                    container = container.border_1().border_color(colors.border_disabled);
                }
            } else {
                container = container.text_color(colors.text_disabled).opacity(0.5);
            }
            container = container.cursor_not_allowed();
        } else {
            if let Some(background) = resolved.background {
                container = container.bg(background);
            }
            if let Some(border) = resolved.border {
                container = container.border_1().border_color(border);
            }

            container = container.cursor(CursorStyle::PointingHand);

            // Keyboard-focus ring: recolor the border when the style draws one,
            // otherwise fall back to the hover background so the ring is visible.
            if resolved.border.is_some() {
                let focus_color = colors.border_focused;
                container =
                    container.focus_visible(move |s: StyleRefinement| s.border_color(focus_color));
            } else if let Some(hover) = resolved.hover {
                container = container.focus_visible(move |s: StyleRefinement| s.bg(hover));
            }

            container = match (resolved.hover, resolved.active) {
                (Some(hover), Some(active)) => container
                    .hover(move |s| s.bg(hover))
                    .active(move |s| s.bg(active)),
                (Some(hover), None) => container.hover(move |s| s.bg(hover)),
                (None, Some(active)) => container.active(move |s| s.bg(active)),
                (None, None) => container,
            };

            if let Some(on_click) = self.on_click {
                container = container
                    .on_mouse_down(MouseButton::Left, |_, window, _| window.prevent_default())
                    .on_click(on_click);
            }
        }

        container = container.children(self.children);

        if let Some(tooltip) = self.tooltip {
            container = container.tooltip(move |window, cx| tooltip(window, cx));
        }

        container
    }
}

/// A clickable button with optional icon and label.
#[derive(IntoElement)]
pub struct Button {
    id: ElementId,
    label: SharedString,
    label_color: Option<Color>,
    icon: Option<IconName>,
    icon_position: IconPosition,
    style: ButtonStyle,
    size: ButtonSize,
    disabled: bool,
    selected: bool,
    full_width: bool,
    tab_index: isize,
    tooltip: Option<TooltipBuilder>,
    on_click: Option<crate::ClickHandler>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum IconPosition {
    #[default]
    Start,
    End,
}

impl Button {
    pub fn new(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            label_color: None,
            icon: None,
            icon_position: IconPosition::Start,
            style: ButtonStyle::default(),
            size: ButtonSize::default(),
            disabled: false,
            selected: false,
            full_width: false,
            tab_index: 0,
            tooltip: None,
            on_click: None,
        }
    }

    /// Set a plain-text tooltip.
    pub fn tooltip(mut self, tooltip: impl Into<SharedString>) -> Self {
        self.tooltip = Some(Box::new(Tooltip::text(tooltip.into())));
        self
    }

    /// Set a tooltip from a factory closure matching GPUI's native `.tooltip()`
    /// signature, allowing richer tooltips (for example with a shortcut hint).
    pub fn tooltip_fn(
        mut self,
        tooltip: impl Fn(&mut Window, &mut App) -> AnyView + 'static,
    ) -> Self {
        self.tooltip = Some(Box::new(tooltip));
        self
    }

    pub fn style(mut self, style: ButtonStyle) -> Self {
        self.style = style;
        self
    }

    pub fn size(mut self, size: ButtonSize) -> Self {
        self.size = size;
        self
    }

    pub fn icon(mut self, icon: IconName) -> Self {
        self.icon = Some(icon);
        self
    }

    pub fn icon_position(mut self, pos: IconPosition) -> Self {
        self.icon_position = pos;
        self
    }

    pub fn color(mut self, color: Color) -> Self {
        self.label_color = Some(color);
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

    pub fn full_width(mut self) -> Self {
        self.full_width = true;
        self
    }

    /// Set the keyboard tab-navigation index. Defaults to `0`, which makes the
    /// button focusable and reachable via Tab.
    pub fn tab_index(mut self, tab_index: isize) -> Self {
        self.tab_index = tab_index;
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

impl RenderOnce for Button {
    fn render(self, _window: &mut Window, _cx: &mut App) -> impl IntoElement {
        let label_color = if self.disabled {
            Color::Disabled
        } else if self.selected {
            Color::Accent
        } else {
            self.label_color.unwrap_or(Color::Default)
        };

        let icon_el = self.icon.map(|name| {
            Icon::new(name)
                .size(self.size.icon_size())
                .color(label_color)
        });
        let label_el = Label::new(self.label)
            .size(self.size.label_size())
            .color(label_color);

        let mut base = ButtonLike::new(self.id)
            .style(self.style)
            .size(self.size)
            .disabled(self.disabled)
            .full_width(self.full_width)
            .tab_index(self.tab_index)
            .on_click(self.on_click);

        if let Some(tooltip) = self.tooltip {
            base = base.tooltip(tooltip);
        }

        match self.icon_position {
            IconPosition::Start => base.children(icon_el).child(label_el),
            IconPosition::End => base.child(label_el).children(icon_el),
        }
    }
}

/// An icon-only button.
#[derive(IntoElement)]
pub struct IconButton {
    id: ElementId,
    icon: IconName,
    color: Color,
    style: ButtonStyle,
    size: ButtonSize,
    disabled: bool,
    selected: bool,
    tab_index: isize,
    tooltip: Option<TooltipBuilder>,
    on_click: Option<crate::ClickHandler>,
}

impl IconButton {
    pub fn new(id: impl Into<ElementId>, icon: IconName) -> Self {
        Self {
            id: id.into(),
            icon,
            color: Color::Default,
            style: ButtonStyle::Subtle,
            size: ButtonSize::Default,
            disabled: false,
            selected: false,
            tab_index: 0,
            tooltip: None,
            on_click: None,
        }
    }

    /// Set a plain-text tooltip.
    pub fn tooltip(mut self, tooltip: impl Into<SharedString>) -> Self {
        self.tooltip = Some(Box::new(Tooltip::text(tooltip.into())));
        self
    }

    /// Set a tooltip from a factory closure matching GPUI's native `.tooltip()`
    /// signature, allowing richer tooltips (for example with a shortcut hint).
    pub fn tooltip_fn(
        mut self,
        tooltip: impl Fn(&mut Window, &mut App) -> AnyView + 'static,
    ) -> Self {
        self.tooltip = Some(Box::new(tooltip));
        self
    }

    pub fn color(mut self, color: Color) -> Self {
        self.color = color;
        self
    }

    pub fn style(mut self, style: ButtonStyle) -> Self {
        self.style = style;
        self
    }

    pub fn size(mut self, size: ButtonSize) -> Self {
        self.size = size;
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

    /// Set the keyboard tab-navigation index. Defaults to `0`, which makes the
    /// button focusable and reachable via Tab.
    pub fn tab_index(mut self, tab_index: isize) -> Self {
        self.tab_index = tab_index;
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

impl RenderOnce for IconButton {
    fn render(self, _window: &mut Window, _cx: &mut App) -> impl IntoElement {
        let icon_color = if self.disabled {
            Color::Disabled
        } else if self.selected {
            Color::Accent
        } else {
            self.color
        };

        let icon_el = Icon::new(self.icon)
            .size(self.size.icon_size())
            .color(icon_color);

        let mut base = ButtonLike::new(self.id)
            .style(self.style)
            .size(self.size)
            .disabled(self.disabled)
            .fixed_size(true)
            .tab_index(self.tab_index)
            .on_click(self.on_click);

        if let Some(tooltip) = self.tooltip {
            base = base.tooltip(tooltip);
        }

        base.child(icon_el)
    }
}
