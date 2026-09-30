use std::sync::Arc;

use gpui::{point, px, App, BoxShadow, Global, Hsla, Styled};
use rgitui_settings::AppearanceMode;
use serde::Serialize;

use crate::colors::{
    catppuccin_latte_colors, catppuccin_latte_status, catppuccin_mocha_colors,
    catppuccin_mocha_status, cream_blue_colors, cream_blue_status, dracula_colors, dracula_status,
    github_dark_colors, github_dark_status, high_contrast_dark_colors, high_contrast_dark_status,
    one_dark_colors, one_dark_status, StatusColors, ThemeColors,
};

/// Visual appearance mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    Light,
    Dark,
}

/// A complete theme definition.
#[derive(Debug, Clone, Serialize)]
pub struct Theme {
    pub name: String,
    pub appearance: Appearance,
    pub colors: ThemeColors,
    pub status: StatusColors,
}

/// Global theme state stored in GPUI's global system.
pub struct ThemeState {
    active: Arc<Theme>,
    available: Vec<Arc<Theme>>,
}

impl Global for ThemeState {}

fn upsert_theme_by_name(available: &mut Vec<Arc<Theme>>, theme: Arc<Theme>) {
    if let Some(existing) = available.iter_mut().find(|t| t.name == theme.name) {
        *existing = theme;
    } else {
        available.push(theme);
    }
}

impl ThemeState {
    pub fn theme(&self) -> &Arc<Theme> {
        &self.active
    }

    pub fn appearance(&self) -> Appearance {
        self.active.appearance
    }

    pub fn available_themes(&self) -> &[Arc<Theme>] {
        &self.available
    }

    /// Returns themes filtered by the given appearance mode.
    pub fn themes_for_appearance(&self, mode: AppearanceMode) -> Vec<Arc<Theme>> {
        match mode {
            AppearanceMode::Auto => self.available.clone(),
            AppearanceMode::Light => self
                .available
                .iter()
                .filter(|t| t.appearance == Appearance::Light)
                .cloned()
                .collect(),
            AppearanceMode::Dark => self
                .available
                .iter()
                .filter(|t| t.appearance == Appearance::Dark)
                .cloned()
                .collect(),
        }
    }

    pub fn set_theme_by_name(&mut self, name: &str) {
        if let Some(theme) = self.available.iter().find(|t| t.name == name) {
            self.active = theme.clone();
        }
    }

    /// Set the active theme directly (used for custom themes).
    pub fn set_active_theme(&mut self, theme: Arc<Theme>) {
        self.active = theme;
    }

    /// Insert a custom theme into the available list and activate it.
    /// If a theme with the same name already exists, it is replaced.
    pub fn insert_theme(&mut self, theme: Arc<Theme>) {
        upsert_theme_by_name(&mut self.available, theme.clone());
        self.active = theme;
    }
}

/// Convenience trait to access the theme from App context.
pub trait ActiveTheme {
    fn theme(&self) -> &Arc<Theme>;
    fn colors(&self) -> &ThemeColors;
    fn status(&self) -> &StatusColors;
}

impl ActiveTheme for App {
    fn theme(&self) -> &Arc<Theme> {
        self.global::<ThemeState>().theme()
    }

    fn colors(&self) -> &ThemeColors {
        &self.global::<ThemeState>().theme().colors
    }

    fn status(&self) -> &StatusColors {
        &self.global::<ThemeState>().theme().status
    }
}

/// Build all built-in themes.
///
/// This is the source of truth for the built-in themes loaded at runtime by
/// [`init`]. They are defined in Rust so they are always available and cannot
/// drift from on-disk assets. JSON is used at runtime only for user-defined
/// themes loaded from the config directory and for exporting/importing themes.
pub fn builtin_themes() -> Vec<Arc<Theme>> {
    vec![
        Arc::new(Theme {
            name: "Catppuccin Mocha".into(),
            appearance: Appearance::Dark,
            colors: catppuccin_mocha_colors(),
            status: catppuccin_mocha_status(),
        }),
        Arc::new(Theme {
            name: "Catppuccin Latte".into(),
            appearance: Appearance::Light,
            colors: catppuccin_latte_colors(),
            status: catppuccin_latte_status(),
        }),
        Arc::new(Theme {
            name: "Cream & Blue".into(),
            appearance: Appearance::Light,
            colors: cream_blue_colors(),
            status: cream_blue_status(),
        }),
        Arc::new(Theme {
            name: "One Dark".into(),
            appearance: Appearance::Dark,
            colors: one_dark_colors(),
            status: one_dark_status(),
        }),
        Arc::new(Theme {
            name: "GitHub Dark".into(),
            appearance: Appearance::Dark,
            colors: github_dark_colors(),
            status: github_dark_status(),
        }),
        Arc::new(Theme {
            name: "Dracula".into(),
            appearance: Appearance::Dark,
            colors: dracula_colors(),
            status: dracula_status(),
        }),
        Arc::new(Theme {
            name: "High Contrast Dark".into(),
            appearance: Appearance::Dark,
            colors: high_contrast_dark_colors(),
            status: high_contrast_dark_status(),
        }),
    ]
}

/// Initialize the theme system. Must be called during app init.
///
/// Built-in themes come from [`builtin_themes`]; any user-defined JSON themes
/// in the config directory are loaded on top, replacing a built-in only when
/// their names match.
pub fn init(cx: &mut App) {
    let mut available = builtin_themes();

    let themes_dir = crate::json_theme::themes_dir();
    if let Ok(entries) = std::fs::read_dir(&themes_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "json") {
                match std::fs::read_to_string(&path) {
                    Ok(json) => match crate::json_theme::load_theme_from_json(&json) {
                        Ok(theme) => {
                            log::info!("Loaded custom theme: {}", theme.name);
                            upsert_theme_by_name(&mut available, Arc::new(theme));
                        }
                        Err(e) => log::warn!("Failed to parse theme {}: {}", path.display(), e),
                    },
                    Err(e) => log::warn!("Failed to read theme {}: {}", path.display(), e),
                }
            }
        }
    }

    let active = available[0].clone(); // Catppuccin Mocha default
    cx.set_global(ThemeState { active, available });
}

// -- Elevation helpers --

/// Elevation levels for layered surfaces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ElevationIndex {
    Background,
    Surface,
    ElevatedSurface,
    ModalSurface,
}

impl ElevationIndex {
    pub fn bg(&self, cx: &App) -> Hsla {
        let colors = cx.colors();
        match self {
            ElevationIndex::Background => colors.background,
            ElevationIndex::Surface => colors.surface_background,
            ElevationIndex::ElevatedSurface => colors.elevated_surface_background,
            ElevationIndex::ModalSurface => colors.elevated_surface_background,
        }
    }

    pub fn shadow(&self) -> Vec<BoxShadow> {
        let black = |a: f32| Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a,
        };
        match self {
            ElevationIndex::Background => vec![],
            ElevationIndex::Surface => vec![BoxShadow {
                color: black(0.05),
                offset: point(px(0.), px(1.)),
                blur_radius: px(2.),
                spread_radius: px(0.),
                inset: false,
            }],
            ElevationIndex::ElevatedSurface => vec![
                BoxShadow {
                    color: black(0.08),
                    offset: point(px(0.), px(2.)),
                    blur_radius: px(4.),
                    spread_radius: px(0.),
                    inset: false,
                },
                BoxShadow {
                    color: black(0.04),
                    offset: point(px(0.), px(1.)),
                    blur_radius: px(2.),
                    spread_radius: px(0.),
                    inset: false,
                },
            ],
            ElevationIndex::ModalSurface => vec![
                BoxShadow {
                    color: black(0.12),
                    offset: point(px(0.), px(4.)),
                    blur_radius: px(8.),
                    spread_radius: px(0.),
                    inset: false,
                },
                BoxShadow {
                    color: black(0.08),
                    offset: point(px(0.), px(2.)),
                    blur_radius: px(4.),
                    spread_radius: px(0.),
                    inset: false,
                },
                BoxShadow {
                    color: black(0.06),
                    offset: point(px(0.), px(8.)),
                    blur_radius: px(16.),
                    spread_radius: px(0.),
                    inset: false,
                },
            ],
        }
    }
}

/// Extension trait providing Zed-like styling helpers on any Styled element.
pub trait StyledExt: Styled + Sized {
    /// Horizontal flex layout with centered items.
    fn h_flex(self) -> Self {
        self.flex().flex_row().items_center()
    }

    /// Vertical flex layout.
    fn v_flex(self) -> Self {
        self.flex().flex_col()
    }

    /// Surface elevation — panels, tab bars.
    fn elevation_1(self, cx: &App) -> Self {
        let colors = cx.colors();
        let shadows = ElevationIndex::Surface.shadow();
        self.bg(colors.surface_background)
            .rounded_lg()
            .border_1()
            .border_color(colors.border)
            .shadow(shadows)
    }

    /// Elevated surface — dropdowns, menus, floating panels.
    fn elevation_2(self, cx: &App) -> Self {
        let colors = cx.colors();
        let shadows = ElevationIndex::ElevatedSurface.shadow();
        self.bg(colors.elevated_surface_background)
            .rounded_lg()
            .border_1()
            .border_color(colors.border)
            .shadow(shadows)
    }

    /// Modal surface — dialogs, modals.
    fn elevation_3(self, cx: &App) -> Self {
        let colors = cx.colors();
        let shadows = ElevationIndex::ModalSurface.shadow();
        self.bg(colors.elevated_surface_background)
            .rounded_lg()
            .border_1()
            .border_color(colors.border)
            .shadow(shadows)
    }

    /// Apply a primary border using the theme's main border color.
    fn border_primary(self, cx: &App) -> Self {
        let colors = cx.colors();
        self.border_1().border_color(colors.border)
    }

    /// Apply a muted/subtle border using the theme's variant border color.
    fn border_muted(self, cx: &App) -> Self {
        let colors = cx.colors();
        self.border_1().border_color(colors.border_variant)
    }

    /// Apply a focused border using the theme's focused border color.
    fn border_focused_style(self, cx: &App) -> Self {
        let colors = cx.colors();
        self.border_1().border_color(colors.border_focused)
    }

    /// Apply the muted text color from the active theme.
    fn text_color_muted(self, cx: &App) -> Self {
        let colors = cx.colors();
        self.text_color(colors.text_muted)
    }
}

impl<E: Styled> StyledExt for E {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upsert_theme_by_name_replaces_existing_theme() {
        let mut available = builtin_themes();
        let replacement = Arc::new(Theme {
            name: "Catppuccin Mocha".into(),
            appearance: Appearance::Light,
            colors: catppuccin_latte_colors(),
            status: catppuccin_latte_status(),
        });

        upsert_theme_by_name(&mut available, replacement.clone());

        assert_eq!(available.len(), builtin_themes().len());
        let stored = available
            .iter()
            .find(|theme| theme.name == "Catppuccin Mocha")
            .expect("replacement theme should be present");
        assert_eq!(stored.appearance, Appearance::Light);
    }

    #[test]
    fn upsert_theme_by_name_inserts_new_theme() {
        let mut available = builtin_themes();
        let initial_len = available.len();
        let new_theme = Arc::new(Theme {
            name: "My Custom Theme".into(),
            appearance: Appearance::Dark,
            colors: catppuccin_mocha_colors(),
            status: catppuccin_mocha_status(),
        });

        upsert_theme_by_name(&mut available, new_theme.clone());

        assert_eq!(available.len(), initial_len + 1);
        let stored = available
            .iter()
            .find(|theme| theme.name == "My Custom Theme")
            .expect("new theme should be present");
        assert_eq!(stored.appearance, Appearance::Dark);
        // Existing themes should be unaffected
        assert!(available.iter().any(|t| t.name == "Catppuccin Mocha"));
    }
}
