//! A dropdown select.
//!
//! The component library had no Select, no Combobox and no searchable picker,
//! so every closed choice in settings was rendered as a row of pills — which
//! is why a four-item model list overflowed the default window.
//!
//! State (open/closed, highlighted row) is owned here, because a stateless
//! popover cannot support keyboard navigation, and the settings page had no
//! keyboard support at all.

use gpui::prelude::*;
use gpui::{
    anchored, deferred, div, px, App, ClickEvent, Context, ElementId, EventEmitter, FocusHandle,
    Focusable, KeyDownEvent, Render, SharedString, StyleRefinement, Window,
};
use rgitui_theme::{ActiveTheme, Color, StyledExt};

use crate::{Icon, IconName, IconSize, Label, LabelSize};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelectOption {
    pub id: SharedString,
    pub label: SharedString,
    /// Second line, rendered muted.
    pub detail: Option<SharedString>,
    pub icon: Option<IconName>,
    pub disabled: bool,
}

impl SelectOption {
    pub fn new(id: impl Into<SharedString>, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            detail: None,
            icon: None,
            disabled: false,
        }
    }

    pub fn detail(mut self, detail: impl Into<SharedString>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    pub fn icon(mut self, icon: IconName) -> Self {
        self.icon = Some(icon);
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }
}

#[derive(Debug, Clone)]
pub enum SelectEvent {
    Changed(SharedString),
    Dismissed,
}

/// Move a highlight by `delta`, skipping disabled rows so Enter can never
/// commit one, and clamping at both ends rather than wrapping.
///
/// Pure, so the whole keyboard-navigation contract is testable without a
/// display.
pub fn next_enabled_option(options: &[SelectOption], from: usize, delta: isize) -> usize {
    if options.is_empty() {
        return 0;
    }
    let len = options.len() as isize;
    let mut index = from as isize;
    for _ in 0..len {
        index = (index + delta).clamp(0, len - 1);
        if !options[index as usize].disabled {
            return index as usize;
        }
        // Every remaining candidate in this direction is disabled.
        if index == 0 || index == len - 1 {
            break;
        }
    }
    from.min(options.len().saturating_sub(1))
}

pub struct Select {
    id: ElementId,
    options: Vec<SelectOption>,
    selected: Option<SharedString>,
    placeholder: SharedString,
    open: bool,
    highlighted: usize,
    full_width: bool,
    disabled: bool,
    tab_index: isize,
    focus_handle: FocusHandle,
}

impl EventEmitter<SelectEvent> for Select {}

impl Focusable for Select {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Select {
    pub fn new(id: impl Into<ElementId>, cx: &mut Context<Self>) -> Self {
        Self {
            id: id.into(),
            options: Vec::new(),
            selected: None,
            placeholder: "Select…".into(),
            open: false,
            highlighted: 0,
            full_width: false,
            disabled: false,
            tab_index: 0,
            focus_handle: cx.focus_handle(),
        }
    }

    pub fn set_options(&mut self, options: Vec<SelectOption>, cx: &mut Context<Self>) {
        self.options = options;
        self.highlighted = self.selected_index().unwrap_or(0);
        cx.notify();
    }

    pub fn set_selected(&mut self, id: Option<SharedString>, cx: &mut Context<Self>) {
        self.selected = id;
        self.highlighted = self.selected_index().unwrap_or(0);
        cx.notify();
    }

    pub fn set_placeholder(
        &mut self,
        placeholder: impl Into<SharedString>,
        cx: &mut Context<Self>,
    ) {
        self.placeholder = placeholder.into();
        cx.notify();
    }

    pub fn set_full_width(&mut self, full_width: bool, cx: &mut Context<Self>) {
        self.full_width = full_width;
        cx.notify();
    }

    pub fn set_disabled(&mut self, disabled: bool, cx: &mut Context<Self>) {
        self.disabled = disabled;
        if disabled {
            self.open = false;
        }
        cx.notify();
    }

    pub fn set_tab_index(&mut self, tab_index: isize, cx: &mut Context<Self>) {
        self.tab_index = tab_index;
        cx.notify();
    }

    pub fn selected(&self) -> Option<&SharedString> {
        self.selected.as_ref()
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    fn selected_index(&self) -> Option<usize> {
        let selected = self.selected.as_ref()?;
        self.options
            .iter()
            .position(|option| &option.id == selected)
    }

    /// The text shown on the closed trigger.
    fn trigger_label(&self) -> SharedString {
        // A selection that is no longer in the option list still shows its raw
        // id rather than reverting to the placeholder: a pinned model that has
        // left the catalogue must stay visible and changeable.
        match self.selected_index() {
            Some(index) => self.options[index].label.clone(),
            None => self
                .selected
                .clone()
                .filter(|selected| !selected.is_empty())
                .unwrap_or_else(|| self.placeholder.clone()),
        }
    }

    pub fn toggle(&mut self, cx: &mut Context<Self>) {
        if self.disabled {
            return;
        }
        self.open = !self.open;
        if self.open {
            self.highlighted = self.selected_index().unwrap_or(0);
        } else {
            cx.emit(SelectEvent::Dismissed);
        }
        cx.notify();
    }

    /// Close the menu, emitting `Dismissed` if it was open.
    ///
    /// For a host that owns an Esc binding: gpui runs a binding before this
    /// element's own key listener, so the listener never sees that Esc.
    pub fn close(&mut self, cx: &mut Context<Self>) {
        if !self.open {
            return;
        }
        self.open = false;
        cx.emit(SelectEvent::Dismissed);
        cx.notify();
    }

    fn commit(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(option) = self.options.get(index) else {
            return;
        };
        if option.disabled {
            return;
        }
        let id = option.id.clone();
        self.selected = Some(id.clone());
        self.open = false;
        cx.emit(SelectEvent::Changed(id));
        cx.notify();
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let key = event.keystroke.key.as_str();
        if !self.open {
            if matches!(key, "enter" | "space" | "down") {
                self.toggle(cx);
                cx.stop_propagation();
            }
            return;
        }

        match key {
            "escape" => self.close(cx),
            "enter" => {
                let index = self.highlighted;
                self.commit(index, cx);
            }
            "down" => {
                self.highlighted = next_enabled_option(&self.options, self.highlighted, 1);
                cx.notify();
            }
            "up" => {
                self.highlighted = next_enabled_option(&self.options, self.highlighted, -1);
                cx.notify();
            }
            "home" => {
                self.highlighted = next_enabled_option(&self.options, 0, 0)
                    .min(self.options.len().saturating_sub(1));
                if self
                    .options
                    .get(self.highlighted)
                    .is_some_and(|option| option.disabled)
                {
                    self.highlighted = next_enabled_option(&self.options, 0, 1);
                }
                cx.notify();
            }
            "end" => {
                let last = self.options.len().saturating_sub(1);
                self.highlighted = if self.options.get(last).is_some_and(|o| o.disabled) {
                    next_enabled_option(&self.options, last, -1)
                } else {
                    last
                };
                cx.notify();
            }
            _ => return,
        }
        cx.stop_propagation();
    }
}

impl Render for Select {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let colors = cx.colors().clone();
        let label = self.trigger_label();
        let is_placeholder = self.selected.is_none();

        let mut trigger = div()
            .id(self.id.clone())
            .track_focus(&self.focus_handle)
            .tab_index(self.tab_index)
            // Not `h_flex()`: this row owns its own alignment and the forced
            // vertical centring interferes once a detail line is present.
            .flex()
            .flex_row()
            .items_center()
            .gap(px(6.))
            .h(px(30.))
            .px(px(10.))
            .rounded(px(6.))
            .border_1()
            .border_color(colors.border)
            .bg(if self.disabled {
                colors.element_disabled
            } else {
                colors.editor_background
            })
            .focus_visible({
                let focused = colors.border_focused;
                move |style: StyleRefinement| style.border_color(focused)
            })
            .on_key_down(cx.listener(Self::on_key_down))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(
                        Label::new(label)
                            .size(LabelSize::Small)
                            .color(if self.disabled {
                                Color::Disabled
                            } else if is_placeholder {
                                Color::Muted
                            } else {
                                Color::Default
                            }),
                    ),
            )
            .child(
                Icon::new(IconName::ChevronDown)
                    .size(IconSize::XSmall)
                    .color(Color::Muted),
            );

        if self.full_width {
            trigger = trigger.w_full();
        } else {
            trigger = trigger.min_w(px(180.));
        }

        if !self.disabled {
            trigger = trigger
                .cursor_pointer()
                .hover(|style| style.border_color(colors.border_focused))
                .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    cx.stop_propagation();
                    this.toggle(cx);
                }));
        }

        let mut container = div().relative().child(trigger);
        if self.full_width {
            container = container.w_full();
        }

        if !self.open {
            return container;
        }

        let mut menu = div()
            .id("select-menu")
            .flex()
            .flex_col()
            .min_w(px(200.))
            .max_h(px(280.))
            .overflow_y_scroll()
            .py(px(4.))
            .rounded(px(6.))
            .border_1()
            .border_color(colors.border)
            .bg(colors.elevated_surface_background)
            .elevation_2(cx);

        for (index, option) in self.options.iter().enumerate() {
            let is_selected = self.selected.as_ref() == Some(&option.id);
            let is_highlighted = index == self.highlighted;
            let disabled = option.disabled;

            let mut row = div()
                .id(ElementId::NamedInteger(
                    "select-option".into(),
                    index as u64,
                ))
                .flex()
                .flex_row()
                .items_center()
                .gap(px(6.))
                .mx(px(4.))
                .px(px(8.))
                .py(px(4.))
                .rounded(px(4.))
                .when(is_highlighted && !disabled, |el| {
                    el.bg(colors.element_selected)
                })
                .when_some(option.icon, |el, icon| {
                    el.child(Icon::new(icon).size(IconSize::XSmall).color(Color::Muted))
                })
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .flex_1()
                        .min_w_0()
                        .child(
                            Label::new(option.label.clone())
                                .size(LabelSize::Small)
                                .color(if disabled {
                                    Color::Disabled
                                } else {
                                    Color::Default
                                }),
                        )
                        .when_some(option.detail.clone(), |el, detail| {
                            el.child(
                                Label::new(detail)
                                    .size(LabelSize::XSmall)
                                    .color(Color::Muted),
                            )
                        }),
                )
                .when(is_selected, |el| {
                    el.child(
                        Icon::new(IconName::Check)
                            .size(IconSize::XSmall)
                            .color(Color::Accent),
                    )
                });

            if !disabled {
                row = row
                    .cursor_pointer()
                    .hover(|style| style.bg(colors.ghost_element_hover))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        cx.stop_propagation();
                        this.commit(index, cx);
                    }));
            }

            menu = menu.child(row);
        }

        container.child(deferred(
            anchored()
                .snap_to_window_with_margin(px(8.))
                .child(div().absolute().top(px(34.)).child(menu)),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options(specs: &[(&str, bool)]) -> Vec<SelectOption> {
        specs
            .iter()
            .map(|(id, disabled)| SelectOption::new(*id, *id).disabled(*disabled))
            .collect()
    }

    fn nav(specs: &[(&str, bool)], from: usize, delta: isize) -> usize {
        next_enabled_option(&options(specs), from, delta)
    }

    #[test]
    fn arrow_navigation_moves_one_row_at_a_time() {
        let specs = [("a", false), ("b", false), ("c", false)];
        assert_eq!(nav(&specs, 0, 1), 1);
        assert_eq!(nav(&specs, 1, 1), 2);
        assert_eq!(nav(&specs, 2, -1), 1);
    }

    #[test]
    fn navigation_clamps_at_both_ends_rather_than_wrapping() {
        let specs = [("a", false), ("b", false)];
        assert_eq!(nav(&specs, 1, 1), 1);
        assert_eq!(nav(&specs, 0, -1), 0);
    }

    /// Enter must never commit a disabled row, so the highlight skips them.
    #[test]
    fn navigation_skips_disabled_rows() {
        let specs = [("a", false), ("b", true), ("c", false)];
        assert_eq!(nav(&specs, 0, 1), 2);
        assert_eq!(nav(&specs, 2, -1), 0);
    }

    #[test]
    fn navigation_on_an_empty_list_stays_put_instead_of_panicking() {
        assert_eq!(nav(&[], 0, 1), 0);
        assert_eq!(nav(&[], 0, -1), 0);
    }

    #[test]
    fn a_run_of_disabled_rows_at_the_edge_leaves_the_highlight_where_it_was() {
        let specs = [("a", false), ("b", true), ("c", true)];
        assert_eq!(nav(&specs, 0, 1), 0);
    }

    #[test]
    fn option_builders_compose() {
        let option = SelectOption::new("id", "Label")
            .detail("1M ctx")
            .icon(IconName::Sparkle)
            .disabled(true);
        assert_eq!(option.id, "id");
        assert_eq!(option.detail.as_deref(), Some("1M ctx"));
        assert_eq!(option.icon, Some(IconName::Sparkle));
        assert!(option.disabled);
    }

    mod headless {
        use gpui::Entity;
        use rgitui_test_support::ViewTest;

        use super::*;

        struct Host {
            select: Entity<Select>,
            dismissed: usize,
        }

        impl Host {
            fn new(_window: &mut Window, cx: &mut Context<Self>) -> Self {
                let select = cx.new(|cx| {
                    let mut select = Select::new("select", cx);
                    select.set_options(options(&[("a", false), ("b", false)]), cx);
                    select
                });
                cx.subscribe(&select, |host: &mut Self, _, event: &SelectEvent, _| {
                    if let SelectEvent::Dismissed = event {
                        host.dismissed += 1;
                    }
                })
                .detach();
                Self {
                    select,
                    dismissed: 0,
                }
            }
        }

        impl Render for Host {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
                div().child(self.select.clone())
            }
        }

        /// The settings window closes an open dropdown on Esc before closing
        /// itself, which relies on `close` reporting a dismissal once and
        /// doing nothing to a dropdown that is already shut.
        #[test]
        fn close_dismisses_an_open_menu_once_and_leaves_a_closed_one_alone() {
            let mut view = ViewTest::open(Host::new);
            view.update(|host, _, cx| {
                host.select.update(cx, |select, cx| {
                    select.toggle(cx);
                    select.close(cx);
                    select.close(cx);
                });
            });
            view.read(|host, cx| {
                assert!(!host.select.read(cx).is_open());
                assert_eq!(host.dismissed, 1);
            });
        }
    }
}
