use gpui::{div, Div};
use rgitui_theme::StyledExt;

/// Create a horizontal flex container (row, items centered).
pub fn h_flex() -> Div {
    div().h_flex()
}

/// Create a vertical flex container (column).
pub fn v_flex() -> Div {
    div().v_flex()
}
