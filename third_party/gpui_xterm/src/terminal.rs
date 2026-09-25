use crate::event::GpuiEventProxy;
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::selection::Selection;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::Processor;
use parking_lot::Mutex;
use std::sync::Arc;

struct TermDimensions {
    columns: usize,
    screen_lines: usize,
}

impl TermDimensions {
    fn new(columns: usize, screen_lines: usize) -> Self {
        Self {
            columns,
            screen_lines,
        }
    }
}

impl Dimensions for TermDimensions {
    fn total_lines(&self) -> usize {
        self.screen_lines
    }

    fn screen_lines(&self) -> usize {
        self.screen_lines
    }

    fn columns(&self) -> usize {
        self.columns
    }

    fn last_column(&self) -> alacritty_terminal::index::Column {
        alacritty_terminal::index::Column(self.columns.saturating_sub(1))
    }
}

pub struct TerminalState {
    term: Arc<Mutex<Term<GpuiEventProxy>>>,

    parser: Processor,

    cols: usize,

    rows: usize,
}

impl TerminalState {
    pub fn new(cols: usize, rows: usize, event_proxy: GpuiEventProxy) -> Self {
        Self::with_scrollback(cols, rows, Config::default().scrolling_history, event_proxy)
    }

    /// Lithe patch: the upstream constructor ignored `TerminalConfig::scrollback`
    /// because it always built `Config::default()`. This constructor lets the view
    /// honor the configured scrollback size.
    pub fn with_scrollback(
        cols: usize,
        rows: usize,
        scrolling_history: usize,
        event_proxy: GpuiEventProxy,
    ) -> Self {
        let config = Config {
            scrolling_history,
            ..Config::default()
        };

        let dimensions = TermDimensions::new(cols, rows);

        let term = Term::new(config, &dimensions, event_proxy);

        let parser = Processor::new();

        Self {
            term: Arc::new(Mutex::new(term)),
            parser,
            cols,
            rows,
        }
    }

    pub fn process_bytes(&mut self, bytes: &[u8]) {
        let mut term = self.term.lock();
        self.parser.advance(&mut *term, bytes);
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        self.cols = cols;
        self.rows = rows;

        let mut term = self.term.lock();

        let dimensions = TermDimensions::new(cols, rows);

        term.resize(dimensions);
    }

    pub fn mode(&self) -> TermMode {
        let term = self.term.lock();
        *term.mode()
    }

    pub fn with_term<F, R>(&self, f: F) -> R
    where
        F: FnOnce(&Term<GpuiEventProxy>) -> R,
    {
        let term = self.term.lock();
        f(&term)
    }

    pub fn with_term_mut<F, R>(&self, f: F) -> R
    where
        F: FnOnce(&mut Term<GpuiEventProxy>) -> R,
    {
        let mut term = self.term.lock();
        f(&mut term)
    }

    pub fn cols(&self) -> usize {
        self.cols
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    pub fn scroll_display(&self, scroll: Scroll) {
        let mut term = self.term.lock();
        term.scroll_display(scroll);
    }

    pub fn scroll_to_bottom(&self) {
        self.scroll_display(Scroll::Bottom);
    }

    pub fn clear_selection(&self) {
        let mut term = self.term.lock();
        term.selection = None;
    }

    pub fn update_selection(&self, selection: Option<Selection>) {
        let mut term = self.term.lock();
        term.selection = selection;
    }

    pub fn selection_text(&self) -> Option<String> {
        let term = self.term.lock();
        term.selection_to_string()
    }

    pub fn clear_screen(&mut self) {
        self.process_bytes(b"[3J[H[2J");
        let mut term = self.term.lock();
        term.selection = None;
    }

    pub fn display_offset(&self) -> usize {
        let term = self.term.lock();
        term.grid().display_offset()
    }

    pub fn term_arc(&self) -> Arc<Mutex<Term<GpuiEventProxy>>> {
        Arc::clone(&self.term)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;

    #[test]
    fn test_terminal_creation() {
        let (tx, _rx) = channel();
        let event_proxy = GpuiEventProxy::new(tx);
        let terminal = TerminalState::new(80, 24, event_proxy);

        assert_eq!(terminal.cols(), 80);
        assert_eq!(terminal.rows(), 24);
    }

    #[test]
    fn test_process_bytes() {
        let (tx, _rx) = channel();
        let event_proxy = GpuiEventProxy::new(tx);
        let mut terminal = TerminalState::new(80, 24, event_proxy);

        terminal.process_bytes(b"Hello, world!");

        terminal.with_term(|term| {
            let grid = term.grid();
            assert!(grid.columns() == 80);
        });
    }

    #[test]
    fn test_clear_screen_resets_cursor_and_display_offset() {
        let (tx, _rx) = channel();
        let event_proxy = GpuiEventProxy::new(tx);
        let mut terminal = TerminalState::new(10, 3, event_proxy);

        terminal.process_bytes(
            b"line1
line2
line3
line4
",
        );
        terminal.scroll_display(Scroll::Top);
        terminal.clear_screen();

        terminal.with_term(|term| {
            assert_eq!(term.grid().display_offset(), 0);
            assert_eq!(term.grid().cursor.point.line.0, 0);
            assert_eq!(term.grid().cursor.point.column.0, 0);
        });
    }

    #[test]
    fn test_scroll_to_bottom_resets_display_offset() {
        let (tx, _rx) = channel();
        let event_proxy = GpuiEventProxy::new(tx);
        let mut terminal = TerminalState::new(10, 3, event_proxy);

        terminal.process_bytes(
            b"line1
line2
line3
line4
",
        );
        terminal.scroll_display(Scroll::Top);

        assert!(terminal.display_offset() > 0);

        terminal.scroll_to_bottom();

        assert_eq!(terminal.display_offset(), 0);
    }

    #[test]
    fn test_resize() {
        let (tx, _rx) = channel();
        let event_proxy = GpuiEventProxy::new(tx);
        let mut terminal = TerminalState::new(80, 24, event_proxy);

        terminal.resize(120, 30);

        assert_eq!(terminal.cols(), 120);
        assert_eq!(terminal.rows(), 30);

        terminal.with_term(|term| {
            let grid = term.grid();
            assert_eq!(grid.columns(), 120);
            assert_eq!(grid.screen_lines(), 30);
        });
    }

    #[test]
    fn test_mode() {
        let (tx, _rx) = channel();
        let event_proxy = GpuiEventProxy::new(tx);
        let terminal = TerminalState::new(80, 24, event_proxy);

        let mode = terminal.mode();
        let _bits = mode.bits();
    }

    #[test]
    fn test_with_term() {
        let (tx, _rx) = channel();
        let event_proxy = GpuiEventProxy::new(tx);
        let terminal = TerminalState::new(80, 24, event_proxy);

        let cols = terminal.with_term(|term| term.grid().columns());
        assert_eq!(cols, 80);
    }

    #[test]
    fn test_with_term_mut() {
        let (tx, _rx) = channel();
        let event_proxy = GpuiEventProxy::new(tx);
        let terminal = TerminalState::new(80, 24, event_proxy);

        terminal.with_term_mut(|term| {
            let _grid = term.grid_mut();
        });
    }

    #[test]
    fn test_term_arc() {
        let (tx, _rx) = channel();
        let event_proxy = GpuiEventProxy::new(tx);
        let terminal = TerminalState::new(80, 24, event_proxy);

        let arc1 = terminal.term_arc();
        let arc2 = terminal.term_arc();

        assert!(Arc::ptr_eq(&arc1, &arc2));
    }
}
