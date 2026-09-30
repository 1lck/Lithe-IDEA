mod avatar_cache;
mod badge;
mod button;
mod checkbox;
mod context_menu;
mod diff_stat;
mod disclosure;
mod divider;
mod fuzzy;
mod icon;
mod indicator;
mod label;
mod list_item;
mod modal;
mod picker;
mod scroll_list;
mod scrollbar;
mod select;
mod spinner;
mod stack;
mod status_pill;
mod tab_bar;
mod text_input;
mod toast;
mod tooltip;
mod window_controls;

pub use avatar_cache::*;
pub use badge::*;
pub use button::*;
pub use checkbox::*;
pub use context_menu::*;
pub use diff_stat::*;
pub use disclosure::*;
pub use divider::*;
pub use fuzzy::*;
pub use icon::*;
pub use indicator::*;
pub use label::*;
pub use list_item::*;
pub use modal::*;
pub use picker::*;
pub use scroll_list::*;
pub use scrollbar::*;
pub use select::*;
pub use spinner::*;
pub use stack::*;
pub use status_pill::*;
pub use tab_bar::*;
pub use text_input::*;
pub use toast::*;
pub use tooltip::*;
pub use window_controls::*;

// Re-export theme helpers that UI components need
pub use rgitui_theme::{ActiveTheme, Color, StyledExt};

/// Common click handler type used across UI components.
pub type ClickHandler = Box<dyn Fn(&gpui::ClickEvent, &mut gpui::Window, &mut gpui::App) + 'static>;
