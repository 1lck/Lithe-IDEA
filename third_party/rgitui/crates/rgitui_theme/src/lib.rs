mod colors;
pub mod json_theme;
mod theme;

pub use colors::*;
pub use theme::*;

/// Set the active theme by name. Convenience wrapper around ThemeState.
pub fn set_theme(name: &str, cx: &mut gpui::App) {
    use gpui::BorrowAppContext;
    cx.update_global::<ThemeState, _>(|state: &mut ThemeState, _cx| {
        state.set_theme_by_name(name);
    });
}

/// Return the names of all available built-in themes.
pub fn available_themes(cx: &gpui::App) -> Vec<String> {
    cx.global::<ThemeState>()
        .available_themes()
        .iter()
        .map(|t| t.name.clone())
        .collect()
}
