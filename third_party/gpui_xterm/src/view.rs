use crate::colors::ColorPalette;
use crate::event::{GpuiEventProxy, TerminalEvent};
use crate::input::keystroke_to_bytes;
use crate::mouse::pixel_to_cell;
use crate::render::TerminalRenderer;
use crate::terminal::TerminalState;
use alacritty_terminal::grid::Scroll;
use alacritty_terminal::index::Side;
use alacritty_terminal::selection::{Selection, SelectionType};
use gpui::{Edges, ElementInputHandler, EntityInputHandler, UTF16Selection, *};
use gpui_component::menu::{ContextMenuExt, PopupMenu, PopupMenuItem};
use std::io::{Cursor, Read, Write};
use std::sync::Arc;
use std::sync::mpsc;
use std::thread;

const CONTEXT: &str = "GpuiXterm";

actions!(gpui_xterm, [SendTab, SendBacktab]);

#[derive(Clone, Debug)]
pub struct TerminalConfig {
    pub cols: usize,

    pub rows: usize,

    pub font_family: String,

    pub font_size: Pixels,

    pub scrollback: usize,

    pub line_height_multiplier: f32,

    pub padding: Edges<Pixels>,

    pub colors: ColorPalette,
}

impl Default for TerminalConfig {
    fn default() -> Self {
        Self {
            cols: 80,
            rows: 24,
            font_family: "monospace".into(),
            font_size: px(14.0),
            scrollback: 10000,
            line_height_multiplier: 1.0,
            padding: Edges::all(px(0.0)),
            colors: ColorPalette::default(),
        }
    }
}

pub type ResizeCallback = Box<dyn Fn(usize, usize) + Send + Sync>;

pub type KeyHandler = Box<dyn Fn(&KeyDownEvent) -> bool + Send + Sync>;

pub type BellCallback = Box<dyn Fn(&mut Window, &mut Context<TerminalView>)>;

pub type TitleCallback = Box<dyn Fn(&mut Window, &mut Context<TerminalView>, &str)>;

pub type ClipboardStoreCallback = Box<dyn Fn(&mut Window, &mut Context<TerminalView>, &str)>;

pub type ExitCallback = Box<dyn Fn(&mut Window, &mut Context<TerminalView>)>;

#[derive(Clone, Copy, Debug, Default)]
struct LayoutMetrics {
    origin: Point<Pixels>,
    cell_width: Pixels,
    cell_height: Pixels,
    cols: usize,
}

pub struct TerminalView {
    state: TerminalState,

    renderer: TerminalRenderer,

    focus_handle: FocusHandle,

    stdin_writer: Arc<parking_lot::Mutex<Box<dyn Write + Send>>>,

    event_rx: mpsc::Receiver<TerminalEvent>,

    config: TerminalConfig,

    #[allow(dead_code)]
    _reader_task: Task<()>,

    resize_callback: Option<Arc<ResizeCallback>>,

    key_handler: Option<Arc<KeyHandler>>,

    bell_callback: Option<BellCallback>,

    title_callback: Option<TitleCallback>,

    clipboard_store_callback: Option<ClipboardStoreCallback>,

    exit_callback: Option<ExitCallback>,

    layout_metrics: Arc<parking_lot::Mutex<LayoutMetrics>>,

    dragging_selection: bool,

    ime_text: String,
    ime_marked_range: Option<std::ops::Range<usize>>,
}

fn should_defer_text_input_to_ime(event: &KeyDownEvent) -> bool {
    event.keystroke.key_char.is_some()
        && !event.keystroke.modifiers.control
        && !event.keystroke.modifiers.alt
        && !event.keystroke.modifiers.platform
        && !event.keystroke.modifiers.function
}

impl TerminalView {
    pub fn new<W, R>(
        stdin_writer: W,
        stdout_reader: R,
        config: TerminalConfig,
        cx: &mut Context<Self>,
    ) -> Self
    where
        W: Write + Send + 'static,
        R: Read + Send + 'static,
    {
        cx.bind_keys([
            KeyBinding::new("tab", SendTab, Some(CONTEXT)),
            KeyBinding::new("shift-tab", SendBacktab, Some(CONTEXT)),
        ]);

        let (event_tx, event_rx) = mpsc::channel();

        let exit_event_tx = event_tx.clone();

        let event_proxy = GpuiEventProxy::new(event_tx);

        let state = TerminalState::with_scrollback(
            config.cols,
            config.rows,
            config.scrollback,
            event_proxy,
        );

        let renderer = TerminalRenderer::new(
            config.font_family.clone(),
            config.font_size,
            config.line_height_multiplier,
            config.colors.clone(),
        );

        let focus_handle = cx.focus_handle().tab_stop(false);

        let stdin_writer = Arc::new(parking_lot::Mutex::new(
            Box::new(stdin_writer) as Box<dyn Write + Send>
        ));

        let (bytes_tx, bytes_rx) = flume::unbounded::<Vec<u8>>();

        thread::spawn(move || {
            Self::read_stdout_blocking(stdout_reader, bytes_tx);
        });

        let reader_task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            loop {
                match bytes_rx.recv_async().await {
                    Ok(bytes) => {
                        let result = this.update(cx, |view: &mut Self, cx: &mut Context<Self>| {
                            view.state.process_bytes(&bytes);
                            cx.notify();
                        });
                        if result.is_err() {
                            break;
                        }
                    }
                    Err(_) => {
                        let _ = exit_event_tx.send(TerminalEvent::Exit);
                        let _ = this.update(cx, |_view, cx: &mut Context<Self>| {
                            cx.notify();
                        });
                        break;
                    }
                }
            }
        });

        Self {
            state,
            renderer,
            focus_handle,
            stdin_writer,
            event_rx,
            config,
            _reader_task: reader_task,
            resize_callback: None,
            key_handler: None,
            bell_callback: None,
            title_callback: None,
            clipboard_store_callback: None,
            exit_callback: None,
            layout_metrics: Arc::new(parking_lot::Mutex::new(LayoutMetrics::default())),
            dragging_selection: false,
            ime_text: String::new(),
            ime_marked_range: None,
        }
    }

    pub fn new_virtual(config: TerminalConfig, cx: &mut Context<Self>) -> Self {
        Self::new(std::io::sink(), Cursor::new(Vec::<u8>::new()), config, cx)
    }

    pub fn with_resize_callback(
        mut self,
        callback: impl Fn(usize, usize) + Send + Sync + 'static,
    ) -> Self {
        self.resize_callback = Some(Arc::new(Box::new(callback)));
        self
    }

    pub fn with_key_handler(
        mut self,
        handler: impl Fn(&KeyDownEvent) -> bool + Send + Sync + 'static,
    ) -> Self {
        self.key_handler = Some(Arc::new(Box::new(handler)));
        self
    }

    pub fn with_bell_callback(
        mut self,
        callback: impl Fn(&mut Window, &mut Context<TerminalView>) + 'static,
    ) -> Self {
        self.bell_callback = Some(Box::new(callback));
        self
    }

    pub fn with_title_callback(
        mut self,
        callback: impl Fn(&mut Window, &mut Context<TerminalView>, &str) + 'static,
    ) -> Self {
        self.title_callback = Some(Box::new(callback));
        self
    }

    pub fn with_clipboard_store_callback(
        mut self,
        callback: impl Fn(&mut Window, &mut Context<TerminalView>, &str) + 'static,
    ) -> Self {
        self.clipboard_store_callback = Some(Box::new(callback));
        self
    }

    pub fn with_exit_callback(
        mut self,
        callback: impl Fn(&mut Window, &mut Context<TerminalView>) + 'static,
    ) -> Self {
        self.exit_callback = Some(Box::new(callback));
        self
    }

    fn read_stdout_blocking<R: Read + Send + 'static>(
        mut stdout_reader: R,
        bytes_tx: flume::Sender<Vec<u8>>,
    ) {
        let mut buffer = [0u8; 4096];

        loop {
            match stdout_reader.read(&mut buffer) {
                Ok(0) => {
                    break;
                }
                Ok(n) => {
                    let bytes = buffer[..n].to_vec();
                    if bytes_tx.send(bytes).is_err() {
                        break;
                    }
                }
                Err(_) => {
                    break;
                }
            }
        }
    }

    fn on_action_send_tab(&mut self, _: &SendTab, _window: &mut Window, _cx: &mut Context<Self>) {
        if self.write_input_bytes(b"\t") {
            _cx.notify();
        }
    }

    fn on_action_send_backtab(
        &mut self,
        _: &SendBacktab,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) {
        if self.write_input_bytes(b"\x1b[Z") {
            _cx.notify();
        }
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, _cx: &mut Context<Self>) {
        if let Some(ref handler) = self.key_handler
            && handler(event)
        {
            return;
        }

        let key = event.keystroke.key.to_lowercase();
        if event.keystroke.modifiers.control && key == "c" && self.copy_selection() {
            return;
        }

        if event.keystroke.modifiers.control && key == "v" && self.paste_from_clipboard() {
            _cx.notify();
            return;
        }

        if should_defer_text_input_to_ime(event) {
            return;
        }

        if key == "tab" {
            let wrote = self.write_input_bytes(if event.keystroke.modifiers.shift {
                b"\x1b[Z"
            } else {
                b"\t"
            });
            if wrote {
                _cx.notify();
            }
            return;
        }

        if let Some(bytes) = keystroke_to_bytes(&event.keystroke, self.state.mode()) {
            if self.write_input_bytes(&bytes) {
                _cx.notify();
            }
        }
    }

    fn on_mouse_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        window.focus(&self.focus_handle, cx);
        let selection_type = match event.click_count {
            2 => SelectionType::Semantic,
            3.. => SelectionType::Lines,
            _ => SelectionType::Simple,
        };
        if let Some(point) = self.hit_test_cell(event.position) {
            self.state
                .update_selection(Some(Selection::new(selection_type, point, Side::Left)));
            self.dragging_selection = true;
            cx.notify();
        }
    }

    fn on_mouse_up(&mut self, event: &MouseUpEvent, _window: &mut Window, cx: &mut Context<Self>) {
        if let Some(point) = self.hit_test_cell(event.position) {
            self.update_selection_endpoint(point);
        }
        self.dragging_selection = false;
        let _ = self.copy_selection();
        cx.notify();
    }

    fn on_mouse_move(
        &mut self,
        event: &MouseMoveEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.dragging_selection || !event.dragging() {
            return;
        }
        if let Some(point) = self.hit_test_cell(event.position) {
            self.update_selection_endpoint(point);
            cx.notify();
        }
    }

    fn on_scroll(
        &mut self,
        event: &ScrollWheelEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let delta = match event.delta {
            ScrollDelta::Lines(delta) => delta.y.round() as i32,
            ScrollDelta::Pixels(delta) => {
                let line_height: f32 = self.renderer.cell_height.into();
                if line_height <= 0.0 {
                    0
                } else {
                    (f32::from(delta.y) / line_height).round() as i32
                }
            }
        };
        if delta != 0 {
            self.state.scroll_display(Scroll::Delta(delta));
            cx.notify();
        }
    }

    fn hit_test_cell(&self, position: Point<Pixels>) -> Option<alacritty_terminal::index::Point> {
        let metrics = *self.layout_metrics.lock();
        if metrics.cell_width <= px(0.0) || metrics.cell_height <= px(0.0) {
            return None;
        }
        if position.x < metrics.origin.x || position.y < metrics.origin.y {
            return None;
        }
        let mut point = pixel_to_cell(
            position,
            metrics.origin,
            metrics.cell_width,
            metrics.cell_height,
        );
        if point.column.0 >= metrics.cols {
            point.column = alacritty_terminal::index::Column(metrics.cols.saturating_sub(1));
        }
        let offset = self.state.display_offset() as i32;
        point.line = alacritty_terminal::index::Line(point.line.0 - offset);
        Some(point)
    }

    fn update_selection_endpoint(&mut self, point: alacritty_terminal::index::Point) {
        self.state.with_term_mut(|term| {
            if let Some(selection) = term.selection.as_mut() {
                selection.update(point, Side::Right);
            }
        });
    }

    fn process_events(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        while let Ok(event) = self.event_rx.try_recv() {
            match event {
                TerminalEvent::Wakeup => {}
                TerminalEvent::Bell => {
                    if let Some(ref callback) = self.bell_callback {
                        callback(window, cx);
                    }
                }
                TerminalEvent::Title(title) => {
                    if let Some(ref callback) = self.title_callback {
                        callback(window, cx, &title);
                    }
                }
                TerminalEvent::ClipboardStore(text) => {
                    if let Some(ref callback) = self.clipboard_store_callback {
                        callback(window, cx, &text);
                    }
                }
                TerminalEvent::ClipboardLoad => {}
                TerminalEvent::Exit => {
                    if let Some(ref callback) = self.exit_callback {
                        callback(window, cx);
                    }
                }
            }
        }
    }

    pub fn dimensions(&self) -> (usize, usize) {
        (self.state.cols(), self.state.rows())
    }

    /// Lithe patch: expose the underlying engine state so the host product can
    /// implement capability the component does not own, such as in-terminal
    /// search, scroll-to-bottom and reading the current display offset. The
    /// component keeps ownership of rendering and input.
    pub fn state(&self) -> &TerminalState {
        &self.state
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        self.state.resize(cols, rows);
    }

    pub fn config(&self) -> &TerminalConfig {
        &self.config
    }

    pub fn focus_handle(&self) -> &FocusHandle {
        &self.focus_handle
    }

    pub fn update_config(&mut self, config: TerminalConfig, cx: &mut Context<Self>) {
        self.renderer.font_family = config.font_family.clone();
        self.renderer.font_size = config.font_size;
        self.renderer.line_height_multiplier = config.line_height_multiplier;
        self.renderer.palette = config.colors.clone();

        self.config = config;

        cx.notify();
    }

    pub fn clear(&mut self, cx: &mut Context<Self>) {
        self.state.clear_screen();
        self.ime_text.clear();
        self.ime_marked_range = None;
        cx.notify();
    }

    pub fn has_selection(&self) -> bool {
        self.state
            .selection_text()
            .is_some_and(|text| !text.is_empty())
    }

    pub fn copy_selection(&self) -> bool {
        if let Some(text) = self.state.selection_text()
            && !text.is_empty()
            && let Ok(mut clipboard) = arboard::Clipboard::new()
        {
            let _ = clipboard.set_text(text);
            return true;
        }
        false
    }

    pub fn paste_from_clipboard(&self) -> bool {
        if let Ok(mut clipboard) = arboard::Clipboard::new()
            && let Ok(text) = clipboard.get_text()
        {
            return self.write_input_bytes(text.as_bytes());
        }
        false
    }

    fn write_input_bytes(&self, bytes: &[u8]) -> bool {
        let mut writer = self.stdin_writer.lock();
        if writer.write_all(bytes).is_err() {
            return false;
        }
        if writer.flush().is_err() {
            return false;
        }
        drop(writer);

        self.state.scroll_to_bottom();
        true
    }

    #[allow(dead_code)]
    fn calculate_dimensions(&self, bounds: Bounds<Pixels>) -> (usize, usize) {
        let width_f32: f32 = bounds.size.width.into();
        let height_f32: f32 = bounds.size.height.into();
        let cell_width_f32: f32 = self.renderer.cell_width.into();
        let cell_height_f32: f32 = self.renderer.cell_height.into();

        let cols = ((width_f32 / cell_width_f32) as usize).max(1);
        let rows = ((height_f32 / cell_height_f32) as usize).max(1);
        (cols, rows)
    }

    fn build_context_menu(
        view: WeakEntity<Self>,
        has_selection: bool,
        menu: PopupMenu,
        _window: &mut Window,
        _cx: &mut Context<PopupMenu>,
    ) -> PopupMenu {
        menu.item(
            PopupMenuItem::new("Copy")
                .disabled(!has_selection)
                .on_click({
                    let view = view.clone();
                    move |_, _, cx| {
                        let _ = view.update(cx, |this, _| {
                            let _ = this.copy_selection();
                        });
                    }
                }),
        )
        .item(PopupMenuItem::new("Paste").on_click({
            let view = view.clone();
            move |_, _, cx| {
                let _ = view.update(cx, |this, cx| {
                    let _ = this.paste_from_clipboard();
                    cx.notify();
                });
            }
        }))
        .item(PopupMenuItem::separator())
        .item(PopupMenuItem::new("Clear").on_click({
            move |_, _, cx| {
                let _ = view.update(cx, |this, cx| {
                    this.clear(cx);
                });
            }
        }))
    }
}

impl EntityInputHandler for TerminalView {
    fn text_for_range(
        &mut self,
        _range_utf16: std::ops::Range<usize>,
        adjusted_range: &mut Option<std::ops::Range<usize>>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<String> {
        let range = self
            .ime_marked_range
            .clone()
            .unwrap_or(0..self.ime_text.encode_utf16().count());
        *adjusted_range = Some(range);
        Some(self.ime_text.clone())
    }

    fn selected_text_range(
        &mut self,
        _ignore_disabled_input: bool,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection {
            range: 0..0,
            reversed: false,
        })
    }

    fn marked_text_range(
        &self,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<std::ops::Range<usize>> {
        self.ime_marked_range.clone()
    }

    fn unmark_text(&mut self, _window: &mut Window, _cx: &mut Context<Self>) {
        self.ime_marked_range = None;
        self.ime_text.clear();
        _cx.notify();
    }

    fn replace_text_in_range(
        &mut self,
        _range: Option<std::ops::Range<usize>>,
        text: &str,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.ime_marked_range = None;
        self.ime_text.clear();
        if !text.is_empty() {
            let _ = self.write_input_bytes(text.as_bytes());
        }
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        _range: Option<std::ops::Range<usize>>,
        new_text: &str,
        new_selected_range: Option<std::ops::Range<usize>>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.ime_text = new_text.to_string();
        self.ime_marked_range = if new_text.is_empty() {
            None
        } else {
            new_selected_range.or_else(|| Some(0..new_text.encode_utf16().count()))
        };
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        _range_utf16: std::ops::Range<usize>,
        _element_bounds: Bounds<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let metrics = *self.layout_metrics.lock();
        self.state.with_term(|term| {
            let cursor = term.grid().cursor.point;
            let offset = term.grid().display_offset() as i32;
            let visible_row = cursor.line.0 + offset;
            Some(Bounds {
                origin: Point {
                    x: metrics.origin.x + metrics.cell_width * (cursor.column.0 as f32),
                    y: metrics.origin.y + metrics.cell_height * (visible_row as f32),
                },
                size: Size {
                    width: metrics.cell_width.max(px(1.0)),
                    height: metrics.cell_height.max(px(1.0)),
                },
            })
        })
    }

    fn character_index_for_point(
        &mut self,
        _point: Point<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<usize> {
        Some(0)
    }
}

impl Render for TerminalView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.process_events(window, cx);

        let state_arc = self.state.term_arc();
        let renderer = self.renderer.clone();
        let resize_callback = self.resize_callback.clone();
        let padding = self.config.padding;
        let layout_metrics = self.layout_metrics.clone();
        let focus_handle = self.focus_handle.clone();
        let entity = cx.entity();
        let ime_text = self.ime_text.clone();
        let ime_marked_range = self.ime_marked_range.clone();

        div()
            .size_full()
            .bg(self.config.colors.background())
            .track_focus(&self.focus_handle)
            .key_context(CONTEXT)
            .on_action(cx.listener(Self::on_action_send_tab))
            .on_action(cx.listener(Self::on_action_send_backtab))
            .on_key_down(cx.listener(Self::on_key_down))
            .on_mouse_down(MouseButton::Left, cx.listener(Self::on_mouse_down))
            .on_mouse_up(MouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_move(cx.listener(Self::on_mouse_move))
            .on_scroll_wheel(cx.listener(Self::on_scroll))
            .context_menu({
                let view = cx.entity().downgrade();
                let has_selection = self.has_selection();
                move |menu, window, cx| {
                    Self::build_context_menu(view.clone(), has_selection, menu, window, cx)
                }
            })
            .child(
                canvas(
                    move |bounds, _window, _cx| bounds,
                    move |bounds, _, window, cx| {
                        use alacritty_terminal::grid::Dimensions;

                        window.handle_input(
                            &focus_handle,
                            ElementInputHandler::new(bounds, entity.clone()),
                            cx,
                        );

                        let mut measured_renderer = renderer.clone();
                        measured_renderer.measure_cell(window);

                        let available_width: f32 =
                            (bounds.size.width - padding.left - padding.right).into();
                        let available_height: f32 =
                            (bounds.size.height - padding.top - padding.bottom).into();
                        let cell_width_f32: f32 = measured_renderer.cell_width.into();
                        let cell_height_f32: f32 = measured_renderer.cell_height.into();

                        let cols = ((available_width / cell_width_f32) as usize).max(1);
                        let rows = ((available_height / cell_height_f32) as usize).max(1);

                        struct TermSize {
                            cols: usize,
                            rows: usize,
                        }
                        impl Dimensions for TermSize {
                            fn total_lines(&self) -> usize {
                                self.rows
                            }
                            fn screen_lines(&self) -> usize {
                                self.rows
                            }
                            fn columns(&self) -> usize {
                                self.cols
                            }
                            fn last_column(&self) -> alacritty_terminal::index::Column {
                                alacritty_terminal::index::Column(self.cols.saturating_sub(1))
                            }
                            fn bottommost_line(&self) -> alacritty_terminal::index::Line {
                                alacritty_terminal::index::Line(self.rows as i32 - 1)
                            }
                            fn topmost_line(&self) -> alacritty_terminal::index::Line {
                                alacritty_terminal::index::Line(0)
                            }
                        }

                        let mut term = state_arc.lock();
                        let current_cols = term.columns();
                        let current_rows = term.screen_lines();
                        if cols != current_cols || rows != current_rows {
                            if let Some(ref callback) = resize_callback {
                                callback(cols, rows);
                            }
                            term.resize(TermSize { cols, rows });
                        }

                        let origin = Point {
                            x: bounds.origin.x + padding.left,
                            y: bounds.origin.y + padding.top,
                        };
                        *layout_metrics.lock() = LayoutMetrics {
                            origin,
                            cell_width: measured_renderer.cell_width,
                            cell_height: measured_renderer.cell_height,
                            cols,
                        };

                        measured_renderer.paint(
                            bounds,
                            padding,
                            &term,
                            window,
                            cx,
                            (!ime_text.is_empty())
                                .then_some((ime_text.as_str(), ime_marked_range.as_ref())),
                        );
                    },
                )
                .size_full(),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::TerminalConfig;

    #[::core::prelude::v1::test]
    fn test_terminal_config_default_uses_compact_line_height() {
        let config = TerminalConfig::default();

        assert_eq!(config.line_height_multiplier, 1.0);
    }
}
