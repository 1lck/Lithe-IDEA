use gpui::prelude::*;
use gpui::{
    canvas, div, fill, px, rems, size, App, Bounds, Context, EventEmitter, FocusHandle, Focusable,
    HighlightStyle, KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent,
    Pixels, Render, SharedString, Size, StyledText, TextLayout, Window,
};
use rgitui_theme::{ActiveTheme, Color};
use std::ops::Range;

#[derive(Debug, Clone)]
pub enum TextInputEvent {
    Changed(String),
    Submit,
    /// The input lost focus. Lets a listener flush a pending edit that was
    /// never submitted with Enter, rather than silently discarding it.
    Blurred,
}

impl EventEmitter<TextInputEvent> for TextInput {}

// TODO(audit) QUAL-09: this hand-rolls a text editor over on_key_down/key_char
// and implements no EntityInputHandler, so OS-level IME/dead-key/composition is
// not wired up. Migrate to wrap GPUI's Editor (single-line mode) or implement
// EntityInputHandler (replace_text_in_range / replace_and_mark_text_in_range /
// marked_text_range) and register it via window.register_input_handler.
pub struct TextInput {
    text: String,
    placeholder: SharedString,
    cursor: usize,
    selection: Option<usize>,
    dragging: bool,
    focus_handle: FocusHandle,
    text_layout: TextLayout,
    multiline: bool,
    masked: bool,
    font_size: Option<Pixels>,
    compact: bool,
    disabled: bool,
    read_only: bool,
    /// Registered on the first render, because `on_focus_out` needs a
    /// `Window` and construction has none. Dropping it unsubscribes.
    focus_out_subscription: Option<gpui::Subscription>,
}

impl TextInput {
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self {
            text: String::new(),
            placeholder: "".into(),
            cursor: 0,
            selection: None,
            dragging: false,
            focus_handle: cx.focus_handle(),
            text_layout: TextLayout::default(),
            multiline: false,
            masked: false,
            font_size: None,
            compact: false,
            disabled: false,
            read_only: false,
            focus_out_subscription: None,
        }
    }

    pub fn multiline(mut self) -> Self {
        self.multiline = true;
        self
    }

    pub fn set_masked(&mut self, masked: bool) {
        self.masked = masked;
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn set_text(&mut self, text: impl Into<String>, cx: &mut Context<Self>) {
        let mut t: String = text.into();
        if !self.multiline {
            if let Some(nl) = t.find('\n') {
                t.truncate(nl);
            }
        }
        self.text = t;
        self.cursor = self.text.len();
        self.selection = None;
        cx.notify();
    }

    pub fn set_placeholder(&mut self, placeholder: impl Into<SharedString>) {
        self.placeholder = placeholder.into();
    }

    pub fn set_font_size(&mut self, size: Pixels) {
        self.font_size = Some(size);
    }

    /// Use the compact single-line treatment for dense toolbar and filter rows.
    pub fn set_compact(&mut self, compact: bool) {
        self.compact = compact;
    }

    pub fn set_disabled(&mut self, disabled: bool) {
        self.disabled = disabled;
    }

    pub fn set_read_only(&mut self, read_only: bool) {
        self.read_only = read_only;
    }

    pub fn clear(&mut self, cx: &mut Context<Self>) {
        self.text.clear();
        self.cursor = 0;
        self.selection = None;
        cx.notify();
    }

    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    pub fn focus(&self, window: &mut Window, cx: &mut Context<Self>) {
        self.focus_handle.focus(window, cx);
    }

    fn selection_range(&self) -> Option<Range<usize>> {
        self.selection
            .map(|sel| sel.min(self.cursor)..sel.max(self.cursor))
    }

    fn delete_selection(&mut self) -> bool {
        if let Some(range) = self.selection_range() {
            if !range.is_empty() {
                self.text.drain(range.start..range.end);
                self.cursor = range.start;
                self.selection = None;
                return true;
            }
        }
        self.selection = None;
        false
    }

    fn selected_text(&self) -> Option<&str> {
        self.selection_range()
            .filter(|r| !r.is_empty())
            .map(|r| &self.text[r])
    }

    fn prev_boundary(&self) -> usize {
        if self.cursor == 0 {
            return 0;
        }
        let mut p = self.cursor - 1;
        while p > 0 && !self.text.is_char_boundary(p) {
            p -= 1;
        }
        p
    }

    fn next_boundary(&self) -> usize {
        if self.cursor >= self.text.len() {
            return self.text.len();
        }
        let mut p = self.cursor + 1;
        while p < self.text.len() && !self.text.is_char_boundary(p) {
            p += 1;
        }
        p
    }

    fn prev_word_boundary(&self) -> usize {
        let b = self.text.as_bytes();
        let mut p = self.cursor;
        while p > 0 && b.get(p - 1).is_some_and(|c| c.is_ascii_whitespace()) {
            p -= 1;
        }
        while p > 0 && b.get(p - 1).is_some_and(|c| !c.is_ascii_whitespace()) {
            p -= 1;
        }
        p
    }

    fn next_word_boundary(&self) -> usize {
        let b = self.text.as_bytes();
        let len = self.text.len();
        let mut p = self.cursor;
        while p < len && !b[p].is_ascii_whitespace() {
            p += 1;
        }
        while p < len && b[p].is_ascii_whitespace() {
            p += 1;
        }
        p
    }

    fn move_cursor(&mut self, pos: usize, shift: bool) {
        if shift {
            if self.selection.is_none() {
                self.selection = Some(self.cursor);
            }
        } else {
            self.selection = None;
        }
        self.cursor = pos;
    }

    fn word_back(text: &str, pos: usize) -> usize {
        let b = text.as_bytes();
        let mut p = pos;
        while p > 0 && b.get(p - 1).is_some_and(|c| c.is_ascii_whitespace()) {
            p -= 1;
        }
        while p > 0 && b.get(p - 1).is_some_and(|c| !c.is_ascii_whitespace()) {
            p -= 1;
        }
        p
    }

    fn word_forward(text: &str, pos: usize) -> usize {
        let b = text.as_bytes();
        let len = text.len();
        let mut p = pos;
        while p < len && !b[p].is_ascii_whitespace() {
            p += 1;
        }
        p
    }

    fn index_from_position(&self, position: gpui::Point<Pixels>) -> usize {
        let mut idx = match self.text_layout.index_for_position(position) {
            Ok(i) | Err(i) => i.min(self.text.len()),
        };
        while idx > 0 && !self.text.is_char_boundary(idx) {
            idx -= 1;
        }
        idx
    }

    fn handle_mouse_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.disabled {
            return;
        }
        self.focus_handle.focus(window, cx);
        let idx = self.index_from_position(event.position);

        if event.modifiers.shift {
            if self.selection.is_none() {
                self.selection = Some(self.cursor);
            }
            self.cursor = idx;
        } else if event.click_count == 2 {
            self.selection = Some(Self::word_back(&self.text, idx));
            self.cursor = Self::word_forward(&self.text, idx);
        } else if event.click_count >= 3 {
            self.selection = Some(0);
            self.cursor = self.text.len();
        } else {
            self.cursor = idx;
            self.selection = Some(idx);
            self.dragging = true;
        }
        cx.notify();
    }

    fn handle_mouse_up(
        &mut self,
        _event: &MouseUpEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.dragging = false;
        if let Some(range) = self.selection_range() {
            if range.is_empty() {
                self.selection = None;
            }
        }
        cx.notify();
    }

    fn handle_mouse_move(
        &mut self,
        event: &MouseMoveEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.dragging {
            return;
        }
        let idx = self.index_from_position(event.position);
        if idx != self.cursor {
            self.cursor = idx;
            cx.notify();
        }
    }

    fn handle_key_down(
        &mut self,
        event: &KeyDownEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.disabled {
            return;
        }

        let key = event.keystroke.key.as_str();
        let primary = event.keystroke.modifiers.secondary();
        let shift = event.keystroke.modifiers.shift;

        match key {
            "enter" => {
                if self.multiline && !primary && !self.read_only {
                    self.delete_selection();
                    self.text.insert(self.cursor, '\n');
                    self.cursor += 1;
                    cx.emit(TextInputEvent::Changed(self.text.clone()));
                    cx.notify();
                } else {
                    cx.emit(TextInputEvent::Submit);
                }
                return;
            }
            "escape" => return,
            "tab" => return,
            "backspace" => {
                if self.read_only {
                    return;
                }
                if self.delete_selection() {
                    cx.emit(TextInputEvent::Changed(self.text.clone()));
                    cx.notify();
                    return;
                }
                if primary {
                    let t = self.prev_word_boundary();
                    if t < self.cursor {
                        self.text.drain(t..self.cursor);
                        self.cursor = t;
                        cx.emit(TextInputEvent::Changed(self.text.clone()));
                        cx.notify();
                    }
                } else if self.cursor > 0 {
                    let p = self.prev_boundary();
                    self.text.drain(p..self.cursor);
                    self.cursor = p;
                    cx.emit(TextInputEvent::Changed(self.text.clone()));
                    cx.notify();
                }
                return;
            }
            "delete" => {
                if self.read_only {
                    return;
                }
                if self.delete_selection() {
                    cx.emit(TextInputEvent::Changed(self.text.clone()));
                    cx.notify();
                    return;
                }
                if self.cursor < self.text.len() {
                    let n = self.next_boundary();
                    self.text.drain(self.cursor..n);
                    cx.emit(TextInputEvent::Changed(self.text.clone()));
                    cx.notify();
                }
                return;
            }
            "left" => {
                if !shift && self.selection.is_some() {
                    if let Some(r) = self.selection_range() {
                        self.cursor = r.start;
                    }
                    self.selection = None;
                    cx.notify();
                    return;
                }
                let t = if primary {
                    self.prev_word_boundary()
                } else {
                    self.prev_boundary()
                };
                self.move_cursor(t, shift);
                cx.notify();
                return;
            }
            "right" => {
                if !shift && self.selection.is_some() {
                    if let Some(r) = self.selection_range() {
                        self.cursor = r.end;
                    }
                    self.selection = None;
                    cx.notify();
                    return;
                }
                let t = if primary {
                    self.next_word_boundary()
                } else {
                    self.next_boundary()
                };
                self.move_cursor(t, shift);
                cx.notify();
                return;
            }
            "home" => {
                self.move_cursor(0, shift);
                cx.notify();
                return;
            }
            "end" => {
                self.move_cursor(self.text.len(), shift);
                cx.notify();
                return;
            }
            _ => {}
        }

        if primary {
            match key {
                "a" => {
                    self.selection = Some(0);
                    self.cursor = self.text.len();
                    cx.notify();
                    return;
                }
                "c" => {
                    if let Some(s) = self.selected_text() {
                        cx.write_to_clipboard(gpui::ClipboardItem::new_string(s.to_string()));
                    }
                    return;
                }
                "x" => {
                    if let Some(s) = self.selected_text() {
                        cx.write_to_clipboard(gpui::ClipboardItem::new_string(s.to_string()));
                    }
                    if !self.read_only && self.delete_selection() {
                        cx.emit(TextInputEvent::Changed(self.text.clone()));
                        cx.notify();
                    }
                    return;
                }
                "v" => {
                    if self.read_only {
                        return;
                    }
                    if let Some(clip) = cx.read_from_clipboard() {
                        if let Some(paste) = clip.text() {
                            self.delete_selection();
                            let t = if self.multiline {
                                paste.clone()
                            } else {
                                paste.lines().next().unwrap_or("").to_string()
                            };
                            self.text.insert_str(self.cursor, &t);
                            self.cursor += t.len();
                            cx.emit(TextInputEvent::Changed(self.text.clone()));
                            cx.notify();
                        }
                    }
                    return;
                }
                _ => {}
            }
        }

        if self.read_only {
            return;
        }

        if let Some(kc) = &event.keystroke.key_char {
            if !primary {
                self.delete_selection();
                self.text.insert_str(self.cursor, kc);
                self.cursor += kc.len();
                cx.emit(TextInputEvent::Changed(self.text.clone()));
                cx.notify();
            }
        } else if key.len() == 1 && !primary {
            let Some(ch) = key.chars().next() else {
                return;
            };
            if ch.is_ascii_graphic() || ch == ' ' {
                self.delete_selection();
                self.text.insert(self.cursor, ch);
                self.cursor += ch.len_utf8();
                cx.emit(TextInputEvent::Changed(self.text.clone()));
                cx.notify();
            }
        }
    }
}

impl Focusable for TextInput {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Render for TextInput {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.focus_out_subscription.is_none() {
            let handle = self.focus_handle.clone();
            self.focus_out_subscription =
                Some(
                    cx.on_focus_out(&handle, window, |_this, _event, _window, cx| {
                        cx.emit(TextInputEvent::Blurred);
                    }),
                );
        }
        let colors = cx.colors();
        let is_focused = self.focus_handle.is_focused(window);
        // TODO(audit) QUAL-18: clearing the selection on blur from inside the
        // paint pass couples rendering to focus transitions. Move this to a
        // focus-change handler once the project adopts a focus-out element API.
        if !is_focused && self.selection.is_some() {
            self.selection = None;
            self.dragging = false;
        }
        let inactive = self.disabled || self.read_only;
        let border_color = if is_focused && !self.disabled {
            colors.border_focused
        } else {
            colors.border
        };
        let hover_border = colors.border_focused;
        let bg = if inactive {
            colors.element_disabled
        } else if is_focused {
            colors.ghost_element_selected
        } else {
            colors.editor_background
        };
        let cursor_color = colors.text_accent;
        let selection_hl = HighlightStyle {
            color: Some(colors.text),
            background_color: Some(gpui::Hsla {
                a: 0.3,
                ..colors.text_accent
            }),
            ..Default::default()
        };

        let is_empty = self.text.is_empty();
        let cursor_idx = self.cursor;

        let text_color_val = if inactive {
            colors.text_disabled
        } else if is_empty {
            Color::Placeholder.color(cx)
        } else {
            colors.text
        };

        let mut text_style = window.text_style();
        text_style.color = text_color_val;
        let font_size_px = self
            .font_size
            .unwrap_or_else(|| rems(0.875).to_pixels(window.rem_size()));
        text_style.font_size = font_size_px.into();
        let target_line_height = font_size_px + px(6.0);
        text_style.line_height =
            gpui::DefiniteLength::Absolute(gpui::AbsoluteLength::Pixels(target_line_height));

        let mut highlights: Vec<(Range<usize>, HighlightStyle)> = Vec::new();
        if is_focused && !is_empty {
            if let Some(range) = self.selection_range() {
                if !range.is_empty() {
                    highlights.push((range, selection_hl));
                }
            }
        }

        let display_text: SharedString = if is_empty {
            self.placeholder.clone()
        } else if self.masked {
            "*".repeat(self.text.chars().count()).into()
        } else {
            self.text.clone().into()
        };
        let text_element = if highlights.is_empty() {
            StyledText::new(display_text)
        } else {
            StyledText::new(display_text).with_default_highlights(&text_style, highlights.clone())
        };
        self.text_layout = text_element.layout().clone();
        let layout_ref = self.text_layout.clone();

        let cursor_overlay = canvas(
            move |_, _, _| Size::<Pixels>::default(),
            move |bounds, _, window, _cx| {
                if !is_focused {
                    return;
                }
                let idx = if is_empty { 0 } else { cursor_idx };
                let cursor_h = target_line_height;
                if let Some(pos) = layout_ref.position_for_index(idx) {
                    let cursor_rect = Bounds {
                        origin: pos,
                        size: size(px(1.5), cursor_h),
                    };
                    window.paint_quad(fill(cursor_rect, cursor_color));
                } else {
                    let cursor_rect = Bounds {
                        origin: bounds.origin,
                        size: size(px(1.5), cursor_h),
                    };
                    window.paint_quad(fill(cursor_rect, cursor_color));
                }
            },
        )
        .absolute()
        .size_full();

        let min_h = if self.multiline {
            px(60.0)
        } else if self.compact {
            px(24.0)
        } else {
            px(32.0)
        };

        let mut container = div()
            .id(if self.multiline {
                "native-text-area"
            } else {
                "native-text-input"
            })
            // Lets keybindings exclude text fields with `!TextInput`, so an
            // unmodified single-key shortcut cannot steal a typed character.
            .key_context("TextInput")
            .track_focus(&self.focus_handle)
            .on_key_down(cx.listener(Self::handle_key_down))
            .on_mouse_down(MouseButton::Left, cx.listener(Self::handle_mouse_down))
            .on_mouse_up(MouseButton::Left, cx.listener(Self::handle_mouse_up))
            .on_mouse_up_out(MouseButton::Left, cx.listener(Self::handle_mouse_up))
            .on_mouse_move(cx.listener(Self::handle_mouse_move))
            .relative()
            .w_full()
            .min_h(min_h)
            .px(if self.compact { px(8.) } else { px(10.) })
            .py(if self.compact { px(2.) } else { px(5.) })
            .rounded(px(6.))
            .border_1()
            .border_color(border_color)
            .bg(bg)
            .when(!is_focused && !inactive, move |el| {
                el.hover(move |s| s.border_color(hover_border))
            })
            .when(self.disabled, |el| el.cursor_not_allowed())
            .when(!self.disabled, |el| el.cursor_text())
            .text_color(text_color_val)
            .text_size(font_size_px)
            .line_height(target_line_height)
            .when(self.multiline, |el| el.flex().flex_col())
            .overflow_hidden();

        if self.multiline {
            container = container.child(
                div()
                    .id("text-scroll-area")
                    .relative()
                    .w_full()
                    .flex_1()
                    .overflow_y_scroll()
                    .child(text_element)
                    .child(cursor_overlay),
            );
        } else {
            container = container.child(text_element).child(cursor_overlay);
        }

        container
    }
}
