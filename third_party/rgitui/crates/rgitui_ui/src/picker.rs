//! A searchable, virtualized picker.
//!
//! Used for the model list, where a closed pill row cannot work: OpenRouter
//! alone offers hundreds of models, and the two questions that actually decide
//! the choice — "is it cheap" and "does it take tools" — are facets, not
//! substrings.
//!
//! Filtering and ranking are pure functions over `[PickerRow]` so they are
//! testable without a display, per the convention in `CLAUDE.md`.

use gpui::prelude::*;
use gpui::{
    div, px, uniform_list, App, ClickEvent, Context, Div, ElementId, Entity, EventEmitter,
    FocusHandle, Focusable, FontWeight, Hsla, KeyDownEvent, Render, ScrollStrategy, SharedString,
    Stateful, UniformListScrollHandle, Window,
};
use rgitui_theme::{ActiveTheme, Color, StyledExt};

use crate::{
    fuzzy_score, Button, ButtonSize, ButtonStyle, Icon, IconButton, IconName, IconSize, Label,
    LabelSize, TextInput, TextInputEvent,
};

/// One selectable row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PickerRow {
    pub id: SharedString,
    pub primary: SharedString,
    pub secondary: Option<SharedString>,
    /// Right-hand column, e.g. `1M   $0.30/$2.50`.
    pub trailing: Option<SharedString>,
    pub badges: Vec<SharedString>,
    /// Which filter chips this row belongs to.
    pub facets: Vec<SharedString>,
}

impl PickerRow {
    pub fn new(id: impl Into<SharedString>, primary: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            primary: primary.into(),
            secondary: None,
            trailing: None,
            badges: Vec::new(),
            facets: Vec::new(),
        }
    }

    pub fn secondary(mut self, secondary: impl Into<SharedString>) -> Self {
        self.secondary = Some(secondary.into());
        self
    }

    pub fn trailing(mut self, trailing: impl Into<SharedString>) -> Self {
        self.trailing = Some(trailing.into());
        self
    }

    pub fn badge(mut self, badge: impl Into<SharedString>) -> Self {
        self.badges.push(badge.into());
        self
    }

    pub fn facet(mut self, facet: impl Into<SharedString>) -> Self {
        self.facets.push(facet.into());
        self
    }
}

/// A filter chip above the list. An empty id means "every row".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PickerChip {
    pub id: SharedString,
    pub label: SharedString,
}

impl PickerChip {
    pub fn new(id: impl Into<SharedString>, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
        }
    }
}

#[derive(Debug, Clone)]
pub enum PickerEvent {
    Selected(SharedString),
    Dismissed,
    RefreshRequested,
}

/// Row height, in pixels. Two lines of text plus padding.
const ROW_HEIGHT: f32 = 44.0;

/// Rows shown before the list scrolls.
///
/// The list is given an explicit height from this. A `uniform_list` sized
/// with `flex_1` inside a column that has no fixed height resolves to zero
/// pixels: the search box and chips draw, and the rows never do.
const MAX_VISIBLE_ROWS: usize = 8;

// Match tiers, best first. Each query word scores the best tier it reaches in
// either the id or the display name, and a row's score is the sum over words.
const TIER_EXACT: u32 = 10_000;
const TIER_PREFIX: u32 = 800;
const TIER_WORD_PREFIX: u32 = 600;
const TIER_SUBSTRING: u32 = 400;
const TIER_IGNORING_PUNCTUATION: u32 = 300;
const TIER_SCATTERED: u32 = 100;

/// Score one lowercase query word against one lowercase haystack.
fn word_score(word: &str, haystack: &str) -> Option<u32> {
    if haystack.starts_with(word) {
        return Some(TIER_PREFIX);
    }
    let starts_a_word = haystack.match_indices(word).any(|(index, _)| {
        haystack[..index]
            .chars()
            .next_back()
            .is_none_or(|previous| !previous.is_alphanumeric())
    });
    if starts_a_word {
        return Some(TIER_WORD_PREFIX);
    }
    if haystack.contains(word) {
        return Some(TIER_SUBSTRING);
    }
    let compact_word = alphanumeric(word);
    if !compact_word.is_empty() && alphanumeric(haystack).contains(&compact_word) {
        return Some(TIER_IGNORING_PUNCTUATION);
    }
    fuzzy_score(word, haystack).map(|_| TIER_SCATTERED)
}

fn alphanumeric(text: &str) -> String {
    text.chars().filter(|c| c.is_alphanumeric()).collect()
}

/// Score a row against a query, or `None` when some word of the query matches
/// neither the id nor the display name. Pure.
///
/// Words match independently and in any order, so `sonnet claude` finds
/// `anthropic/claude-sonnet-4.6`, and punctuation is optional, so `gpt5` finds
/// `gpt-5`. Scattered-letter matches still count — that is what surfaces a
/// similar name for a misremembered one — but rank below any row that contains
/// the words outright.
pub fn row_score(row: &PickerRow, query: &str) -> Option<u32> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Some(0);
    }
    let id = row.id.to_lowercase();
    let primary = row.primary.to_lowercase();
    let mut score = 0;
    for word in query.split_whitespace() {
        score += word_score(word, &id).max(word_score(word, &primary))?;
    }
    if id == query || primary == query {
        score += TIER_EXACT;
    }
    Some(score)
}

fn row_in_facet(row: &PickerRow, facet: &str) -> bool {
    facet.is_empty() || row.facets.iter().any(|value| value == facet)
}

/// Indices of the rows carrying `facet` that match `query`, best match first.
/// Pure.
///
/// Equal scores keep the caller's order, which for a server-sorted catalogue
/// is already the most useful ranking there is; an empty query keeps it
/// outright.
pub fn filter_rows(rows: &[PickerRow], query: &str, facet: &str) -> Vec<usize> {
    let mut scored: Vec<(u32, usize)> = rows
        .iter()
        .enumerate()
        .filter(|(_, row)| row_in_facet(row, facet))
        .filter_map(|(index, row)| Some((row_score(row, query)?, index)))
        .collect();
    // Stable, so ties keep the caller's order.
    scored.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    scored.into_iter().map(|(_, index)| index).collect()
}

/// How many rows each chip holds, ignoring the query. Pure.
///
/// A chip holding nothing is not offered: a provider that reports no prices
/// has no cheap models, and a chip that can only ever answer "no matches"
/// reads as a broken filter.
pub fn chip_counts(rows: &[PickerRow], chips: &[PickerChip]) -> Vec<usize> {
    chips
        .iter()
        .map(|chip| {
            rows.iter()
                .filter(|row| row_in_facet(row, &chip.id))
                .count()
        })
        .collect()
}

/// The typed id offered with the matches, when the query could name something
/// that is not in the list. Pure.
///
/// An id never contains whitespace, so a query with a space is a search rather
/// than an id, and a query that already names a row needs no second entry.
pub fn custom_entry(rows: &[PickerRow], query: &str) -> Option<SharedString> {
    let query = query.trim();
    if query.is_empty()
        || query.contains(char::is_whitespace)
        || rows.iter().any(|row| row.id == query)
    {
        return None;
    }
    Some(SharedString::from(query.to_string()))
}

/// One entry in the list: a row, by its index into the rows, or the typed id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PickerEntry {
    Row(usize),
    Custom(SharedString),
}

/// The entries the list shows, in order: the rows carrying `facet` that match
/// `query`, best match first, and the typed id when `allow_custom` is set and
/// no row has it. Pure.
///
/// The order decides what Enter picks, because every change to the query
/// highlights the first entry. A search puts the typed id after the matches,
/// so `sonnet` picks the best match rather than saving `sonnet` as a model. An
/// id — a vendor and a model either side of a slash, which display names never
/// contain — puts it first instead: behind the matches, `vendor/model` would
/// lose Enter to `vendor/model-mini` and save a model the user never named. A
/// row matching the query exactly, in any case, still comes first.
pub fn picker_entries(
    rows: &[PickerRow],
    query: &str,
    facet: &str,
    allow_custom: bool,
) -> Vec<PickerEntry> {
    let matches = filter_rows(rows, query, facet);
    let Some(custom) = allow_custom.then(|| custom_entry(rows, query)).flatten() else {
        return matches.into_iter().map(PickerEntry::Row).collect();
    };
    let names_an_id = custom
        .split_once('/')
        .is_some_and(|(vendor, model)| !vendor.is_empty() && !model.is_empty());
    let exact_match = matches
        .first()
        .and_then(|&row| row_score(&rows[row], query))
        .is_some_and(|score| score >= TIER_EXACT);
    let matching = matches.into_iter().map(PickerEntry::Row);
    let custom = std::iter::once(PickerEntry::Custom(custom));
    if names_an_id && !exact_match {
        custom.chain(matching).collect()
    } else {
        matching.chain(custom).collect()
    }
}

pub struct Picker {
    rows: Vec<PickerRow>,
    chips: Vec<PickerChip>,
    /// Per chip, how many rows it holds regardless of the query.
    chip_counts: Vec<usize>,
    active_chip: SharedString,
    selected_id: Option<SharedString>,
    /// What the list shows for the current rows, chip and query.
    entries: Vec<PickerEntry>,
    allow_custom: bool,
    /// An index into `entries`.
    highlighted: usize,
    query_editor: Entity<TextInput>,
    scroll_handle: UniformListScrollHandle,
    focus_handle: FocusHandle,
    footer_note: Option<SharedString>,
    status_note: Option<SharedString>,
}

impl EventEmitter<PickerEvent> for Picker {}

impl Focusable for Picker {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Picker {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let query_editor = cx.new(|cx| {
            let mut input = TextInput::new(cx);
            input.set_placeholder("Search by name or id…");
            input
        });

        // Only `Changed` is handled. Enter also bubbles to `on_key_down`, so
        // committing on `Submit` as well would select every choice twice.
        cx.subscribe(
            &query_editor,
            |this: &mut Self, _, event: &TextInputEvent, cx| {
                if let TextInputEvent::Changed(_) = event {
                    this.refresh_matches(cx);
                    this.highlight(0, ScrollStrategy::Top, cx);
                }
            },
        )
        .detach();

        Self {
            rows: Vec::new(),
            chips: Vec::new(),
            chip_counts: Vec::new(),
            active_chip: SharedString::default(),
            selected_id: None,
            entries: Vec::new(),
            allow_custom: false,
            highlighted: 0,
            query_editor,
            scroll_handle: UniformListScrollHandle::new(),
            focus_handle: cx.focus_handle(),
            footer_note: None,
            status_note: None,
        }
    }

    pub fn set_rows(&mut self, rows: Vec<PickerRow>, cx: &mut Context<Self>) {
        self.rows = rows;
        self.refresh_matches(cx);
    }

    pub fn set_chips(&mut self, chips: Vec<PickerChip>, cx: &mut Context<Self>) {
        self.chips = chips;
        self.refresh_matches(cx);
    }

    pub fn set_selected(&mut self, id: Option<SharedString>, cx: &mut Context<Self>) {
        self.selected_id = id;
        cx.notify();
    }

    /// Offer the typed query as a choice when no row has that id.
    pub fn set_allow_custom(&mut self, allow_custom: bool, cx: &mut Context<Self>) {
        self.allow_custom = allow_custom;
        self.refresh_matches(cx);
    }

    /// A short line in the footer, e.g. `updated 3 h ago`.
    pub fn set_footer_note(&mut self, note: Option<SharedString>, cx: &mut Context<Self>) {
        self.footer_note = note;
        cx.notify();
    }

    /// A warning shown above the list — a stale catalogue, or a fetch that
    /// failed. Never blanks the list.
    pub fn set_status_note(&mut self, note: Option<SharedString>, cx: &mut Context<Self>) {
        self.status_note = note;
        cx.notify();
    }

    pub fn focus(&self, window: &mut Window, cx: &mut Context<Self>) {
        self.query_editor
            .update(cx, |input, cx| input.focus(window, cx));
    }

    /// Clear the search and the chip, highlight the current selection, and
    /// focus the search box.
    ///
    /// Call each time the picker is shown, so it opens on the model in use
    /// rather than on whatever was typed into it last time.
    pub fn reset(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.query_editor.update(cx, |input, cx| input.clear(cx));
        self.active_chip = SharedString::default();
        self.refresh_matches(cx);
        let selected = self.selected_id.as_ref().and_then(|selected| {
            self.entries.iter().position(
                |entry| matches!(entry, PickerEntry::Row(row) if &self.rows[*row].id == selected),
            )
        });
        self.highlight(selected.unwrap_or(0), ScrollStrategy::Center, cx);
        self.focus(window, cx);
    }

    /// Recompute the chip counts and the entries from the current rows, chip
    /// and query.
    fn refresh_matches(&mut self, cx: &mut Context<Self>) {
        let query = self.query_editor.read(cx).text().to_string();
        self.chip_counts = chip_counts(&self.rows, &self.chips);
        // New rows (another provider, a toggled setting) can empty the active
        // chip, which then disappears; left active, it would strand the list
        // on "no matches" behind a chip the user can no longer see.
        let chip_available = self.active_chip.is_empty()
            || self
                .chips
                .iter()
                .zip(&self.chip_counts)
                .any(|(chip, count)| chip.id == self.active_chip && *count > 0);
        if !chip_available {
            self.active_chip = SharedString::default();
        }
        self.entries = picker_entries(&self.rows, &query, &self.active_chip, self.allow_custom);
        self.highlighted = self.highlighted.min(self.entries.len().saturating_sub(1));
        cx.notify();
    }

    /// The id behind entry `index`: a matching row's, or the typed one.
    fn entry_id(&self, index: usize) -> Option<SharedString> {
        match self.entries.get(index)? {
            PickerEntry::Row(row) => Some(self.rows[*row].id.clone()),
            PickerEntry::Custom(id) => Some(id.clone()),
        }
    }

    fn highlight(&mut self, index: usize, strategy: ScrollStrategy, cx: &mut Context<Self>) {
        let count = self.entries.len();
        self.highlighted = index.min(count.saturating_sub(1));
        if count > 0 {
            self.scroll_handle
                .scroll_to_item(self.highlighted, strategy);
        }
        cx.notify();
    }

    fn move_highlight(&mut self, delta: isize, cx: &mut Context<Self>) {
        let count = self.entries.len();
        if count == 0 {
            return;
        }
        let next = (self.highlighted as isize + delta).clamp(0, count as isize - 1) as usize;
        self.highlight(next, ScrollStrategy::Nearest, cx);
    }

    fn select_chip(&mut self, chip: SharedString, cx: &mut Context<Self>) {
        self.active_chip = chip;
        self.refresh_matches(cx);
        self.highlight(0, ScrollStrategy::Top, cx);
    }

    fn commit(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(id) = self.entry_id(index) else {
            return;
        };
        self.selected_id = Some(id.clone());
        cx.emit(PickerEvent::Selected(id));
        cx.notify();
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let page = MAX_VISIBLE_ROWS as isize;
        match event.keystroke.key.as_str() {
            "escape" => cx.emit(PickerEvent::Dismissed),
            "down" => self.move_highlight(1, cx),
            "up" => self.move_highlight(-1, cx),
            "pagedown" => self.move_highlight(page, cx),
            "pageup" => self.move_highlight(-page, cx),
            "enter" => self.commit(self.highlighted, cx),
            _ => return,
        }
        cx.stop_propagation();
    }
}

/// The check column shared by every entry, so names line up whether or not a
/// row is the current choice.
fn selection_mark(is_selected: bool) -> Div {
    div().w(px(14.)).flex_shrink_0().when(is_selected, |el| {
        el.child(
            Icon::new(IconName::Check)
                .size(IconSize::XSmall)
                .color(Color::Accent),
        )
    })
}

fn row_contents(
    entry: Stateful<Div>,
    row: &PickerRow,
    is_selected: bool,
    badge_background: Hsla,
) -> Stateful<Div> {
    let mut badges = div().flex().flex_row().flex_shrink_0().gap(px(4.));
    for badge in &row.badges {
        badges = badges.child(
            div().px(px(5.)).rounded(px(3.)).bg(badge_background).child(
                Label::new(badge.clone())
                    .size(LabelSize::XSmall)
                    .color(Color::Muted),
            ),
        );
    }

    entry
        .child(selection_mark(is_selected))
        .child(
            div()
                .flex()
                .flex_col()
                .flex_1()
                .min_w_0()
                .child(
                    Label::new(row.primary.clone())
                        .size(LabelSize::Small)
                        .truncate(),
                )
                .when_some(row.secondary.clone(), |el, secondary| {
                    el.child(
                        Label::new(secondary)
                            .size(LabelSize::XSmall)
                            .color(Color::Muted)
                            .truncate(),
                    )
                }),
        )
        .child(badges)
        .when_some(row.trailing.clone(), |el, trailing| {
            el.child(
                div().flex_shrink_0().child(
                    Label::new(trailing)
                        .size(LabelSize::XSmall)
                        .color(Color::Muted),
                ),
            )
        })
}

fn custom_contents(entry: Stateful<Div>, id: &str) -> Stateful<Div> {
    entry.child(selection_mark(false)).child(
        div()
            .flex()
            .flex_col()
            .flex_1()
            .min_w_0()
            .child(
                Label::new(format!("Use “{id}”"))
                    .size(LabelSize::Small)
                    .truncate(),
            )
            .child(
                Label::new("Not in this list — sent to the provider exactly as typed")
                    .size(LabelSize::XSmall)
                    .color(Color::Muted),
            ),
    )
}

impl Render for Picker {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let colors = cx.colors().clone();
        let entry_count = self.entries.len();
        let shown = self
            .entries
            .iter()
            .filter(|entry| matches!(entry, PickerEntry::Row(_)))
            .count();
        let total = self.rows.len();

        // "All" always shows; any other chip only when it holds something.
        let offered_chips: Vec<(&PickerChip, usize)> = self
            .chips
            .iter()
            .zip(self.chip_counts.iter().copied())
            .filter(|(chip, count)| chip.id.is_empty() || *count > 0)
            .collect();

        let mut chip_row = div()
            .flex()
            .flex_row()
            // Wrapping is not optional here: a fixed row of chips is exactly
            // what made the old model pills overflow the window.
            .flex_wrap()
            .items_start()
            .gap(px(4.))
            .px(px(10.))
            .py(px(6.));
        for (chip, count) in &offered_chips {
            let is_active = chip.id == self.active_chip;
            let chip_id = chip.id.clone();
            chip_row = chip_row.child(
                div()
                    .id(ElementId::Name(format!("picker-chip-{}", chip.id).into()))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(5.))
                    .h(px(24.))
                    .px(px(10.))
                    .rounded(px(12.))
                    .cursor_pointer()
                    .bg(if is_active {
                        colors.element_selected
                    } else {
                        colors.element_background
                    })
                    .hover(|style| style.bg(colors.ghost_element_hover))
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        cx.stop_propagation();
                        this.select_chip(chip_id.clone(), cx);
                        // A click lands focus on the picker itself; hand it
                        // back so typing keeps refining the search.
                        this.focus(window, cx);
                    }))
                    .child(
                        Label::new(chip.label.clone())
                            .size(LabelSize::XSmall)
                            .color(if is_active {
                                Color::Default
                            } else {
                                Color::Muted
                            })
                            .weight(if is_active {
                                FontWeight::SEMIBOLD
                            } else {
                                FontWeight::NORMAL
                            }),
                    )
                    .child(
                        Label::new(count.to_string())
                            .size(LabelSize::XSmall)
                            .color(Color::Muted),
                    ),
            );
        }

        let body = if entry_count > 0 {
            let visible_rows = entry_count.min(MAX_VISIBLE_ROWS);
            uniform_list(
                "picker-rows",
                entry_count,
                cx.processor(|this, range: std::ops::Range<usize>, _window, cx| {
                    let colors = cx.colors().clone();
                    range
                        .map(|index| {
                            // The list lays each row out on its own, so a row
                            // with no width is only as wide as its text, and
                            // its highlight and click area stop there.
                            let entry = div()
                                .id(ElementId::NamedInteger("picker-row".into(), index as u64))
                                .w_full()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(px(8.))
                                .h(px(ROW_HEIGHT))
                                .px(px(10.))
                                .cursor_pointer()
                                .when(index == this.highlighted, |el| {
                                    el.bg(colors.element_selected)
                                })
                                .hover(|style| style.bg(colors.ghost_element_hover))
                                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    cx.stop_propagation();
                                    this.commit(index, cx);
                                }));
                            match this.entries.get(index) {
                                Some(PickerEntry::Row(row)) => {
                                    let row = &this.rows[*row];
                                    let is_selected = this.selected_id.as_ref() == Some(&row.id);
                                    row_contents(entry, row, is_selected, colors.element_background)
                                }
                                Some(PickerEntry::Custom(id)) => custom_contents(entry, id),
                                None => entry,
                            }
                            .into_any_element()
                        })
                        .collect::<Vec<_>>()
                }),
            )
            .track_scroll(&self.scroll_handle)
            .h(px(visible_rows as f32 * ROW_HEIGHT))
            // GPUI gives a wheel event to every scroll container under the
            // pointer, so the page scrolled along with the list. The list's
            // own scrolling runs before this listener; stopping the event here
            // keeps it from the page. A list with nothing to scroll lets the
            // wheel through.
            .when(entry_count > MAX_VISIBLE_ROWS, |list| {
                list.on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            })
            .into_any_element()
        } else {
            let query = self.query_editor.read(cx).text().trim().to_string();
            let message = if total == 0 {
                "No models loaded yet".to_string()
            } else if query.is_empty() {
                "No models in this filter".to_string()
            } else {
                format!("No models match “{query}”")
            };
            div()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(4.))
                .h(px(80.))
                .child(
                    Label::new(message)
                        .size(LabelSize::Small)
                        .color(Color::Muted),
                )
                .when(!self.active_chip.is_empty(), |el| {
                    el.child(
                        Button::new("picker-clear-chip", "Search all models")
                            .style(ButtonStyle::Subtle)
                            .size(ButtonSize::Compact)
                            .color(Color::Accent)
                            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                                cx.stop_propagation();
                                this.select_chip(SharedString::default(), cx);
                                this.focus(window, cx);
                            })),
                    )
                })
                .into_any_element()
        };

        div()
            .id("model-picker")
            .track_focus(&self.focus_handle)
            .flex()
            .flex_col()
            .w_full()
            .rounded(px(8.))
            .border_1()
            .border_color(colors.border)
            .bg(colors.elevated_surface_background)
            .elevation_2(cx)
            .on_key_down(cx.listener(Self::on_key_down))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(6.))
                    .px(px(10.))
                    .py(px(8.))
                    .border_b_1()
                    .border_color(colors.border_variant)
                    .child(
                        Icon::new(IconName::Search)
                            .size(IconSize::Small)
                            .color(Color::Muted),
                    )
                    .child(div().flex_1().min_w_0().child(self.query_editor.clone()))
                    .child(
                        IconButton::new("picker-refresh", IconName::Refresh)
                            .size(ButtonSize::Compact)
                            .color(Color::Muted)
                            .tooltip("Refresh the model list")
                            .on_click(cx.listener(|_this, _: &ClickEvent, _, cx| {
                                cx.stop_propagation();
                                cx.emit(PickerEvent::RefreshRequested);
                            })),
                    ),
            )
            .when(offered_chips.len() > 1, |el| el.child(chip_row))
            // A failed refresh shows a note; it never blanks the list, because
            // a stale list is far more use than an empty one.
            .when_some(self.status_note.clone(), |el, note| {
                el.child(
                    div().px(px(10.)).pb(px(4.)).child(
                        Label::new(note)
                            .size(LabelSize::XSmall)
                            .color(Color::Warning),
                    ),
                )
            })
            .child(body)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(10.))
                    .px(px(10.))
                    .py(px(6.))
                    .border_t_1()
                    .border_color(colors.border_variant)
                    .child(
                        Label::new("↑↓ navigate   ⏎ select   esc close")
                            .size(LabelSize::XSmall)
                            .color(Color::Muted),
                    )
                    .child(div().flex_1())
                    .child(
                        Label::new(match &self.footer_note {
                            Some(note) => format!("{shown} of {total} · {note}"),
                            None => format!("{shown} of {total}"),
                        })
                        .size(LabelSize::XSmall)
                        .color(Color::Muted),
                    ),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows() -> Vec<PickerRow> {
        vec![
            PickerRow::new("google/gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite")
                .facet("cheap")
                .facet("tools"),
            PickerRow::new("openai/gpt-5.6-luna", "GPT-5.6 Luna")
                .facet("cheap")
                .facet("tools"),
            PickerRow::new("anthropic/claude-opus-4-6", "Claude Opus 4.6").facet("tools"),
        ]
    }

    fn ids(rows: &[PickerRow], indices: &[usize]) -> Vec<String> {
        indices
            .iter()
            .map(|&index| rows[index].id.to_string())
            .collect()
    }

    #[test]
    fn an_empty_query_preserves_the_supplied_order() {
        assert_eq!(filter_rows(&rows(), "", ""), vec![0, 1, 2]);
        assert_eq!(filter_rows(&rows(), "   ", ""), vec![0, 1, 2]);
    }

    #[test]
    fn a_query_ranks_matches_and_drops_non_matches() {
        let rows = rows();
        assert_eq!(
            ids(&rows, &filter_rows(&rows, "flash", "")),
            ["google/gemini-3.1-flash-lite"]
        );
    }

    #[test]
    fn a_query_matches_the_display_name_as_well_as_the_id() {
        let rows = vec![PickerRow::new("vendor/m-2026", "Moonbeam")];
        assert_eq!(filter_rows(&rows, "moonbeam", ""), vec![0]);
    }

    #[test]
    fn a_query_that_matches_nothing_yields_an_empty_list_not_everything() {
        assert!(filter_rows(&rows(), "zzzzzz", "").is_empty());
    }

    #[test]
    fn ranking_is_case_insensitive() {
        assert_eq!(filter_rows(&rows(), "FLASH", "").len(), 1);
    }

    #[test]
    fn words_match_in_any_order_across_the_id_and_the_name() {
        let rows = vec![
            PickerRow::new("anthropic/claude-opus-5", "Anthropic: Claude Opus 5"),
            PickerRow::new(
                "anthropic/claude-sonnet-4.6",
                "Anthropic: Claude Sonnet 4.6",
            ),
        ];
        assert_eq!(
            ids(&rows, &filter_rows(&rows, "sonnet claude", "")),
            ["anthropic/claude-sonnet-4.6"]
        );
    }

    #[test]
    fn punctuation_in_the_query_is_optional() {
        let rows = rows();
        assert_eq!(
            ids(&rows, &filter_rows(&rows, "gpt56", "")),
            ["openai/gpt-5.6-luna"]
        );
    }

    /// Scattered-letter matches are how a similar name surfaces, but a row
    /// containing the word outright must come first.
    #[test]
    fn a_whole_word_outranks_a_scattered_letter_match_and_both_are_kept() {
        let rows = vec![
            PickerRow::new("vendor/lighthouse", "Lighthouse"),
            PickerRow::new("google/gemini-flash-lite", "Gemini Flash Lite"),
        ];
        assert_eq!(
            ids(&rows, &filter_rows(&rows, "lite", "")),
            ["google/gemini-flash-lite", "vendor/lighthouse"]
        );
    }

    #[test]
    fn an_exact_id_outranks_longer_ids_that_start_with_it() {
        let rows = vec![
            PickerRow::new("openai/gpt-5-mini", "GPT-5 mini"),
            PickerRow::new("openai/gpt-5", "GPT-5"),
        ];
        assert_eq!(
            ids(&rows, &filter_rows(&rows, "openai/gpt-5", "")),
            ["openai/gpt-5", "openai/gpt-5-mini"]
        );
    }

    #[test]
    fn equal_scores_keep_the_supplied_order() {
        let rows = vec![
            PickerRow::new("anthropic/claude-opus-5", "Claude Opus 5"),
            PickerRow::new("anthropic/claude-sonnet-4.6", "Claude Sonnet 4.6"),
        ];
        assert_eq!(filter_rows(&rows, "claude", ""), vec![0, 1]);
    }

    #[test]
    fn an_empty_chip_means_all_rows() {
        assert_eq!(filter_rows(&rows(), "", "").len(), 3);
    }

    #[test]
    fn a_chip_keeps_only_rows_carrying_that_facet() {
        let rows = rows();
        assert_eq!(filter_rows(&rows, "", "cheap").len(), 2);
        assert_eq!(filter_rows(&rows, "", "tools").len(), 3);
        assert_eq!(filter_rows(&rows, "", "free").len(), 0);
    }

    #[test]
    fn chip_and_query_filtering_compose() {
        let rows = rows();
        assert_eq!(
            ids(&rows, &filter_rows(&rows, "gpt", "cheap")),
            ["openai/gpt-5.6-luna"]
        );
    }

    #[test]
    fn chip_counts_ignore_the_query_and_count_empty_chips_as_zero() {
        let chips = vec![
            PickerChip::new("", "All"),
            PickerChip::new("cheap", "Cheap"),
            PickerChip::new("tools", "Tools"),
            PickerChip::new("free", "Free"),
        ];
        assert_eq!(chip_counts(&rows(), &chips), vec![3, 2, 3, 0]);
    }

    #[test]
    fn an_unlisted_id_is_offered_as_a_custom_entry() {
        assert_eq!(
            custom_entry(&rows(), " vendor/new-model ").as_deref(),
            Some("vendor/new-model")
        );
    }

    #[test]
    fn no_custom_entry_for_a_listed_id_a_phrase_or_nothing() {
        assert_eq!(custom_entry(&rows(), "openai/gpt-5.6-luna"), None);
        assert_eq!(custom_entry(&rows(), "claude opus"), None);
        assert_eq!(custom_entry(&rows(), "  "), None);
    }

    #[test]
    fn a_search_keeps_its_best_match_ahead_of_the_typed_id() {
        assert_eq!(
            picker_entries(&rows(), "flash", "", true),
            [PickerEntry::Row(0), PickerEntry::Custom("flash".into())]
        );
    }

    /// Enter picks the first entry, so an id typed in full must not lose it to
    /// a longer listed id that starts the same way.
    #[test]
    fn a_typed_id_leads_the_longer_ids_it_starts() {
        let rows = vec![PickerRow::new("vendor/model-mini", "Vendor: Model Mini")];
        assert_eq!(
            picker_entries(&rows, "vendor/model", "", true),
            [
                PickerEntry::Custom("vendor/model".into()),
                PickerEntry::Row(0)
            ]
        );
    }

    #[test]
    fn a_vendor_alone_is_a_search() {
        assert_eq!(
            picker_entries(&rows(), "google/", "", true).first(),
            Some(&PickerEntry::Row(0))
        );
    }

    #[test]
    fn a_listed_id_typed_in_another_case_still_comes_first() {
        assert_eq!(
            picker_entries(&rows(), "OpenAI/GPT-5.6-Luna", "", true).first(),
            Some(&PickerEntry::Row(1))
        );
    }

    #[test]
    fn no_typed_id_is_offered_unless_allowed() {
        assert_eq!(
            picker_entries(&rows(), "flash", "", false),
            [PickerEntry::Row(0)]
        );
    }

    #[test]
    fn row_builders_compose() {
        let row = PickerRow::new("id", "Primary")
            .secondary("vendor/id")
            .trailing("1M   $0.25/$1.50")
            .badge("Tools")
            .facet("cheap");
        assert_eq!(row.secondary.as_deref(), Some("vendor/id"));
        assert_eq!(row.badges, vec![SharedString::from("Tools")]);
        assert_eq!(row.facets, vec![SharedString::from("cheap")]);
    }

    /// Drives a real picker in a headless window, hosted the way the settings
    /// page hosts it: inside a scroll container with more of the page below
    /// it, in a column with no fixed height.
    mod headless {
        use std::cell::Cell;
        use std::rc::Rc;

        use gpui::{canvas, point, Bounds, MouseButton, Pixels, Point, ScrollHandle};
        use rgitui_test_support::ViewTest;

        use super::*;

        struct Host {
            picker: Entity<Picker>,
            selected: Vec<SharedString>,
            painted_bounds: Rc<Cell<Bounds<Pixels>>>,
            page_scroll: ScrollHandle,
        }

        impl Host {
            fn new(_window: &mut Window, cx: &mut Context<Self>) -> Self {
                let picker = cx.new(Picker::new);
                cx.subscribe(&picker, |host: &mut Self, _, event: &PickerEvent, _| {
                    if let PickerEvent::Selected(id) = event {
                        host.selected.push(id.clone());
                    }
                })
                .detach();
                Self {
                    picker,
                    selected: Vec::new(),
                    painted_bounds: Rc::new(Cell::new(Bounds::default())),
                    page_scroll: ScrollHandle::new(),
                }
            }
        }

        impl Render for Host {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
                let painted_bounds = self.painted_bounds.clone();
                div().size_full().flex().flex_col().child(
                    div()
                        .id("scroll")
                        .flex()
                        .flex_col()
                        .flex_1()
                        .min_h_0()
                        .overflow_y_scroll()
                        .track_scroll(&self.page_scroll)
                        .child(
                            div()
                                .relative()
                                .flex()
                                .flex_col()
                                .w_full()
                                .child(self.picker.clone())
                                .child(
                                    canvas(
                                        move |bounds, _, _| painted_bounds.set(bounds),
                                        |_, _, _, _| {},
                                    )
                                    .absolute()
                                    .size_full(),
                                ),
                        )
                        .child(div().flex_shrink_0().h(px(4000.))),
                )
            }
        }

        fn catalogue() -> Vec<PickerRow> {
            vec![
                PickerRow::new("anthropic/claude-opus-5", "Anthropic: Claude Opus 5")
                    .facet("tools"),
                PickerRow::new(
                    "anthropic/claude-sonnet-4.6",
                    "Anthropic: Claude Sonnet 4.6",
                )
                .facet("tools"),
                PickerRow::new(
                    "google/gemini-3.1-flash-lite",
                    "Google: Gemini 3.1 Flash Lite",
                )
                .facet("cheap")
                .facet("tools"),
            ]
        }

        fn open(rows: Vec<PickerRow>) -> ViewTest<Host> {
            let mut view = ViewTest::open(Host::new);
            view.update(|host, window, cx| {
                host.picker.update(cx, |picker, cx| {
                    picker.set_allow_custom(true, cx);
                    picker.set_rows(rows, cx);
                    picker.reset(window, cx);
                });
            });
            view.draw();
            view
        }

        fn selected(view: &ViewTest<Host>) -> Vec<String> {
            view.read(|host, _| host.selected.iter().map(|id| id.to_string()).collect())
        }

        fn numbered_rows(count: usize) -> Vec<PickerRow> {
            (0..count)
                .map(|index| {
                    PickerRow::new(format!("vendor/model-{index}"), format!("Model {index}"))
                })
                .collect()
        }

        /// Halfway down the picker, which lands on a row: the rows are most of
        /// its height.
        fn picker_middle(view: &ViewTest<Host>) -> Point<Pixels> {
            let bounds = view.read(|host, _| host.painted_bounds.get());
            point(
                bounds.origin.x + bounds.size.width / 2.,
                bounds.origin.y + bounds.size.height / 2.,
            )
        }

        fn page_offset(view: &ViewTest<Host>) -> f32 {
            view.read(|host, _| f32::from(host.page_scroll.offset().y))
        }

        fn list_offset(view: &ViewTest<Host>) -> f32 {
            view.read(|host, cx| {
                let picker = host.picker.read(cx);
                let offset = picker.scroll_handle.0.borrow().base_handle.offset();
                f32::from(offset.y)
            })
        }

        #[test]
        fn a_click_at_the_far_edge_of_a_row_picks_it() {
            let mut view = open(numbered_rows(60));
            let bounds = view.read(|host, _| host.painted_bounds.get());
            let far_edge = point(
                bounds.origin.x + bounds.size.width - px(24.),
                bounds.origin.y + bounds.size.height / 2.,
            );
            view.simulate_click(far_edge, MouseButton::Left);
            assert_eq!(
                selected(&view).len(),
                1,
                "a row should reach the edge of the list, not stop where its text does"
            );
        }

        #[test]
        fn the_wheel_over_a_long_list_scrolls_the_list_and_not_the_page() {
            let mut view = open(numbered_rows(60));
            let middle = picker_middle(&view);
            view.simulate_scroll(middle, point(px(0.), px(-100.)));
            assert!(list_offset(&view) < 0., "the list should have scrolled");
            assert_eq!(page_offset(&view), 0., "the page should not have moved");
        }

        #[test]
        fn the_wheel_over_a_list_with_nothing_to_scroll_moves_the_page() {
            let mut view = open(numbered_rows(3));
            let middle = picker_middle(&view);
            view.simulate_scroll(middle, point(px(0.), px(-100.)));
            assert!(page_offset(&view) < 0., "the page should have scrolled");
        }

        #[test]
        fn rows_take_up_real_height_in_a_column_with_no_fixed_height() {
            let painted_height = |count: usize| {
                open(numbered_rows(count))
                    .read(|host, _| f32::from(host.painted_bounds.get().size.height))
            };
            let three = painted_height(3);
            let sixty = painted_height(60);
            let expected = (MAX_VISIBLE_ROWS - 3) as f32 * ROW_HEIGHT;
            assert!(
                (sixty - three - expected).abs() < 0.5,
                "three rows painted {three}px and sixty painted {sixty}px; \
                 the list should grow by {expected}px before it scrolls"
            );
        }

        #[test]
        fn typing_narrows_the_list_and_enter_picks_the_best_match_once() {
            let mut view = open(catalogue());
            view.simulate_input("sonnet");
            view.simulate_keystroke("enter");
            assert_eq!(selected(&view), ["anthropic/claude-sonnet-4.6"]);
        }

        #[test]
        fn arrow_keys_move_through_similar_matches_before_enter() {
            let mut view = open(catalogue());
            view.simulate_input("claude");
            view.simulate_keystroke("down");
            view.simulate_keystroke("enter");
            assert_eq!(selected(&view), ["anthropic/claude-sonnet-4.6"]);
        }

        #[test]
        fn an_id_missing_from_the_list_can_be_typed_and_chosen() {
            let mut view = open(catalogue());
            view.simulate_input("vendor/unlisted");
            view.simulate_keystroke("enter");
            assert_eq!(selected(&view), ["vendor/unlisted"]);
        }

        #[test]
        fn enter_saves_a_typed_id_rather_than_a_longer_listed_one() {
            let mut view = open(vec![PickerRow::new(
                "vendor/model-mini",
                "Vendor: Model Mini",
            )]);
            view.simulate_input("vendor/model");
            view.simulate_keystroke("enter");
            assert_eq!(selected(&view), ["vendor/model"]);
        }

        #[test]
        fn a_chip_limits_the_list_to_its_facet() {
            let mut view = open(catalogue());
            view.update(|host, _, cx| {
                host.picker.update(cx, |picker, cx| {
                    picker.set_chips(
                        vec![
                            PickerChip::new("", "All"),
                            PickerChip::new("cheap", "Cheap"),
                        ],
                        cx,
                    );
                    picker.select_chip("cheap".into(), cx);
                });
            });
            view.simulate_keystroke("enter");
            assert_eq!(selected(&view), ["google/gemini-3.1-flash-lite"]);
        }

        #[test]
        fn opening_again_starts_from_a_clear_search_on_the_current_choice() {
            let mut view = open(catalogue());
            view.simulate_input("flash");
            view.update(|host, window, cx| {
                host.picker.update(cx, |picker, cx| {
                    picker.set_selected(Some("anthropic/claude-sonnet-4.6".into()), cx);
                    picker.reset(window, cx);
                });
            });
            view.draw();
            view.simulate_keystroke("enter");
            assert_eq!(selected(&view), ["anthropic/claude-sonnet-4.6"]);
        }
    }
}
