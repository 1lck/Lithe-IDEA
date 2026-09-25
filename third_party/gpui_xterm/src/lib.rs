pub mod clipboard;
pub mod colors;
pub mod event;
pub mod input;
pub mod mouse;
pub mod render;
pub mod terminal;
pub mod view;

pub use clipboard::Clipboard;
pub use colors::{ColorPalette, ColorPaletteBuilder};
pub use event::{GpuiEventProxy, TerminalEvent};
pub use render::TerminalRenderer;
pub use terminal::TerminalState;
pub use view::{
    BellCallback, ClipboardStoreCallback, ExitCallback, KeyHandler, ResizeCallback, TerminalConfig,
    TerminalView, TitleCallback,
};
