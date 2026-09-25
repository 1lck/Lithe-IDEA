use std::collections::HashMap;

use anyhow::{anyhow, Result};
use gpui::Hsla;
use serde::Deserialize;

use crate::colors::{hex_to_hsla, StatusColors, ThemeColors};
use crate::theme::{Appearance, Theme};

/// Raw JSON representation of a theme file.
#[derive(Debug, Deserialize)]
struct JsonTheme {
    name: String,
    appearance: String,
    colors: HashMap<String, String>,
    status: HashMap<String, String>,
}

/// Parse a hex color from the map, returning an error if missing.
fn get_color(map: &HashMap<String, String>, key: &str) -> Result<Hsla> {
    let hex = map
        .get(key)
        .ok_or_else(|| anyhow!("missing color key: {}", key))?;
    Ok(hex_to_hsla(hex))
}

/// Parse a hex color from the map, falling back to a default if the key is absent.
fn get_color_or(map: &HashMap<String, String>, key: &str, default: Hsla) -> Hsla {
    map.get(key).map_or(default, |hex| hex_to_hsla(hex))
}

/// Load a complete Theme from a JSON string.
pub fn load_theme_from_json(json: &str) -> Result<Theme> {
    let raw: JsonTheme = serde_json::from_str(json)?;

    let appearance = match raw.appearance.as_str() {
        "light" => Appearance::Light,
        "dark" => Appearance::Dark,
        other => return Err(anyhow!("unknown appearance: {}", other)),
    };

    let c = &raw.colors;
    let s = &raw.status;

    let colors = ThemeColors {
        background: get_color(c, "background")?,
        surface_background: get_color(c, "surface_background")?,
        elevated_surface_background: get_color(c, "elevated_surface_background")?,
        editor_background: get_color(c, "editor_background")?,

        border: get_color(c, "border")?,
        border_variant: get_color(c, "border_variant")?,
        border_focused: get_color(c, "border_focused")?,
        border_selected: get_color(c, "border_selected")?,
        border_disabled: get_color(c, "border_disabled")?,
        border_transparent: get_color(c, "border_transparent")?,

        element_background: get_color(c, "element_background")?,
        element_hover: get_color(c, "element_hover")?,
        element_active: get_color(c, "element_active")?,
        element_selected: get_color(c, "element_selected")?,
        element_disabled: get_color(c, "element_disabled")?,
        ghost_element_background: get_color(c, "ghost_element_background")?,
        ghost_element_hover: get_color(c, "ghost_element_hover")?,
        ghost_element_active: get_color(c, "ghost_element_active")?,
        ghost_element_selected: get_color(c, "ghost_element_selected")?,

        text: get_color(c, "text")?,
        text_muted: get_color(c, "text_muted")?,
        text_placeholder: get_color(c, "text_placeholder")?,
        text_disabled: get_color(c, "text_disabled")?,
        text_accent: get_color(c, "text_accent")?,

        icon: get_color(c, "icon")?,
        icon_muted: get_color(c, "icon_muted")?,
        icon_disabled: get_color(c, "icon_disabled")?,
        icon_accent: get_color(c, "icon_accent")?,

        title_bar_background: get_color(c, "title_bar_background")?,
        toolbar_background: get_color(c, "toolbar_background")?,
        tab_bar_background: get_color(c, "tab_bar_background")?,
        tab_active_background: get_color(c, "tab_active_background")?,
        tab_inactive_background: get_color(c, "tab_inactive_background")?,
        status_bar_background: get_color(c, "status_bar_background")?,
        panel_background: get_color(c, "panel_background")?,
        scrollbar_thumb_background: get_color(c, "scrollbar_thumb_background")?,
        scrollbar_thumb_hover_background: get_color(c, "scrollbar_thumb_hover_background")?,

        hint_background: get_color_or(
            c,
            "hint_background",
            Hsla {
                h: 0.0,
                s: 0.0,
                l: 0.5,
                a: 0.1,
            },
        ),

        vc_added: get_color(c, "vc_added")?,
        vc_modified: get_color(c, "vc_modified")?,
        vc_deleted: get_color(c, "vc_deleted")?,
        vc_conflict: get_color(c, "vc_conflict")?,
        vc_renamed: get_color(c, "vc_renamed")?,
        vc_untracked: get_color(c, "vc_untracked")?,
    };

    let status = StatusColors {
        error: get_color(s, "error")?,
        error_background: get_color(s, "error_background")?,
        warning: get_color(s, "warning")?,
        warning_background: get_color(s, "warning_background")?,
        success: get_color(s, "success")?,
        success_background: get_color(s, "success_background")?,
        info: get_color(s, "info")?,
        info_background: get_color(s, "info_background")?,
        hint: get_color(s, "hint")?,
    };

    Ok(Theme {
        name: raw.name,
        appearance,
        colors,
        status,
    })
}

fn theme_filename(name: &str) -> String {
    let mut slug = String::with_capacity(name.len());
    let mut last_was_dash = false;

    for ch in name.chars() {
        let mapped = if ch.is_ascii_alphanumeric() {
            Some(ch.to_ascii_lowercase())
        } else if ch.is_whitespace() || ch.is_ascii_punctuation() || matches!(ch, '-' | '_') {
            Some('-')
        } else {
            None
        };

        if let Some(ch) = mapped {
            if ch == '-' {
                if last_was_dash || slug.is_empty() {
                    continue;
                }
                last_was_dash = true;
            } else {
                last_was_dash = false;
            }
            slug.push(ch);
        }
    }

    while slug.ends_with('-') {
        slug.pop();
    }

    if slug.is_empty() {
        "theme.json".to_string()
    } else {
        format!("{slug}.json")
    }
}

/// Serialize a theme to a JSON string for saving to disk.
/// The output format is compatible with `load_theme_from_json`.
pub fn serialize_theme_to_json(theme: &Theme) -> Result<String> {
    serde_json::to_string_pretty(theme).map_err(|e| anyhow!("failed to serialize theme: {}", e))
}

/// Where user-defined themes are read from and written to.
///
/// Resolved through `rgitui_settings` rather than from `dirs` directly, so a
/// run with its state redirected — a measured run, which must not read the
/// user's themes or write into their config — reads and writes themes under
/// that root like every other piece of persisted state.
pub fn themes_dir() -> std::path::PathBuf {
    rgitui_settings::config_dir().join("themes")
}

/// Save a theme to the user's themes directory (`<config>/rgitui/themes/`).
/// Creates the directory if it does not exist.
pub fn save_theme_to_file(theme: &Theme) -> Result<std::path::PathBuf> {
    let json = serialize_theme_to_json(theme)?;
    let themes_dir = themes_dir();
    std::fs::create_dir_all(&themes_dir)?;
    let path = themes_dir.join(theme_filename(&theme.name));
    std::fs::write(&path, json)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── helpers ────────────────────────────────────────────────────

    /// Build a minimal valid JSON theme string with every required key.
    fn minimal_dark_theme_json(name: &str) -> String {
        let color = "#1e1e2e";
        let status = "#ff0000";
        format!(
            r#"{{
                "name": "{name}",
                "appearance": "dark",
                "colors": {{
                    "background": "{c}",
                    "surface_background": "{c}",
                    "elevated_surface_background": "{c}",
                    "editor_background": "{c}",
                    "border": "{c}",
                    "border_variant": "{c}",
                    "border_focused": "{c}",
                    "border_selected": "{c}",
                    "border_disabled": "{c}",
                    "border_transparent": "{c}",
                    "element_background": "{c}",
                    "element_hover": "{c}",
                    "element_active": "{c}",
                    "element_selected": "{c}",
                    "element_disabled": "{c}",
                    "ghost_element_background": "{c}",
                    "ghost_element_hover": "{c}",
                    "ghost_element_active": "{c}",
                    "ghost_element_selected": "{c}",
                    "text": "{c}",
                    "text_muted": "{c}",
                    "text_placeholder": "{c}",
                    "text_disabled": "{c}",
                    "text_accent": "{c}",
                    "icon": "{c}",
                    "icon_muted": "{c}",
                    "icon_disabled": "{c}",
                    "icon_accent": "{c}",
                    "title_bar_background": "{c}",
                    "toolbar_background": "{c}",
                    "tab_bar_background": "{c}",
                    "tab_active_background": "{c}",
                    "tab_inactive_background": "{c}",
                    "status_bar_background": "{c}",
                    "panel_background": "{c}",
                    "scrollbar_thumb_background": "{c}",
                    "scrollbar_thumb_hover_background": "{c}",
                    "vc_added": "{c}",
                    "vc_modified": "{c}",
                    "vc_deleted": "{c}",
                    "vc_conflict": "{c}",
                    "vc_renamed": "{c}",
                    "vc_untracked": "{c}"
                }},
                "status": {{
                    "error": "{s}",
                    "error_background": "{s}",
                    "warning": "{s}",
                    "warning_background": "{s}",
                    "success": "{s}",
                    "success_background": "{s}",
                    "info": "{s}",
                    "info_background": "{s}",
                    "hint": "{s}"
                }}
            }}"#,
            name = name,
            c = color,
            s = status,
        )
    }

    // ── load_theme_from_json ───────────────────────────────────────

    #[test]
    fn load_valid_dark_theme() {
        let json = minimal_dark_theme_json("Test Dark");
        let theme = load_theme_from_json(&json).expect("should parse");
        assert_eq!(theme.name, "Test Dark");
        assert_eq!(theme.appearance, crate::theme::Appearance::Dark);
    }

    #[test]
    fn load_valid_light_theme() {
        // Reuse helper, then patch appearance field
        let json = minimal_dark_theme_json("Test Light").replace("\"dark\"", "\"light\"");
        let theme = load_theme_from_json(&json).expect("should parse");
        assert_eq!(theme.appearance, crate::theme::Appearance::Light);
    }

    #[test]
    fn load_unknown_appearance_errors() {
        let json = minimal_dark_theme_json("Bad").replace("\"dark\"", "\"rainbow\"");
        let err = load_theme_from_json(&json).unwrap_err();
        assert!(err.to_string().contains("unknown appearance"));
    }

    #[test]
    fn load_missing_required_color_key_errors() {
        // Remove one required key
        let json =
            minimal_dark_theme_json("Incomplete").replace("\"background\":", "\"_background\":");
        let err = load_theme_from_json(&json).unwrap_err();
        assert!(err.to_string().contains("missing color key"));
    }

    #[test]
    fn load_invalid_json_errors() {
        let err = load_theme_from_json("{not valid json").unwrap_err();
        // anyhow wraps serde_json error
        assert!(!err.to_string().is_empty());
    }

    #[test]
    fn load_optional_hint_background_absent_uses_default() {
        // hint_background has a default — it's OK to omit it
        let json = minimal_dark_theme_json("No Hint");
        // hint_background is not in the minimal template — verify it parses fine
        let theme = load_theme_from_json(&json).expect("should parse without hint_background");
        assert_eq!(theme.name, "No Hint");
    }

    // ── serialize / roundtrip ──────────────────────────────────────

    #[test]
    fn serialize_theme_to_json_produces_valid_json() {
        let theme =
            load_theme_from_json(&minimal_dark_theme_json("Roundtrip Test")).expect("should parse");
        let json = serialize_theme_to_json(&theme).expect("should serialize");
        // Should be parseable as JSON
        let reparsed: serde_json::Value =
            serde_json::from_str(&json).expect("should be valid JSON");
        assert_eq!(reparsed["name"], "Roundtrip Test");
        assert_eq!(reparsed["appearance"], "dark");
        // Colors should be present as hex strings
        let colors = &reparsed["colors"];
        assert!(colors["background"].as_str().unwrap().starts_with('#'));
        // Status should be present
        let status = &reparsed["status"];
        assert!(status["error"].as_str().unwrap().starts_with('#'));
    }

    #[test]
    fn serialize_deserialize_roundtrip() {
        let theme =
            load_theme_from_json(&minimal_dark_theme_json("Roundtrip Test")).expect("should parse");
        let json = serialize_theme_to_json(&theme).expect("should serialize");
        let loaded = load_theme_from_json(&json).expect("should deserialize");
        assert_eq!(loaded.name, theme.name);
        assert_eq!(loaded.appearance, theme.appearance);
        // Verify colors roundtrip (Hsla → #rrggbbaa → Hsla via hex_to_hsla)
        assert_eq!(loaded.colors.background, theme.colors.background);
        assert_eq!(loaded.status.error, theme.status.error);
    }

    #[test]
    fn serialize_deserialize_roundtrip_light_appearance() {
        // A Light theme — ensure Light appearance and all colors roundtrip correctly
        let theme = load_theme_from_json(
            &minimal_dark_theme_json("Light Test").replace("\"dark\"", "\"light\""),
        )
        .expect("should parse");
        assert_eq!(theme.appearance, crate::theme::Appearance::Light);
        let json = serialize_theme_to_json(&theme).expect("should serialize");
        let loaded = load_theme_from_json(&json).expect("should deserialize");
        assert_eq!(loaded.name, theme.name);
        assert_eq!(loaded.appearance, theme.appearance);
        // Surface and elevated surface colors should roundtrip identically
        assert_eq!(
            loaded.colors.surface_background,
            theme.colors.surface_background
        );
        assert_eq!(
            loaded.colors.elevated_surface_background,
            theme.colors.elevated_surface_background
        );
    }

    #[test]
    fn serialize_roundtrip_preserves_alpha_channel() {
        // Build a theme with explicit alpha != 1.0 and verify it roundtrips.
        // Hsla serializes as #RRGGBBAA (8-char with alpha suffix).
        // load_theme_from_json -> hex_to_hsla parses the 8-char form back to Hsla.
        let theme =
            load_theme_from_json(&minimal_dark_theme_json("Roundtrip Test")).expect("should parse");
        let json = serialize_theme_to_json(&theme).expect("should serialize");
        // Verify 8-char hex appears in the serialized JSON (alpha suffix)
        assert!(
            json.contains("#1e1e2e"),
            "serialized JSON should contain background color hex"
        );
        let loaded = load_theme_from_json(&json).expect("should deserialize with alpha");
        // Alpha channel must be preserved through the roundtrip
        assert_eq!(loaded.colors.background, theme.colors.background);
        assert_eq!(loaded.colors.text, theme.colors.text);
    }

    #[test]
    fn theme_filename_slugifies_for_cross_platform_paths() {
        assert_eq!(theme_filename("My Theme"), "my-theme.json");
        assert_eq!(theme_filename(" Theme:/Name? *v2* "), "theme-name-v2.json");
    }

    #[test]
    fn theme_filename_falls_back_when_name_has_no_safe_characters() {
        assert_eq!(theme_filename(":/\\*?"), "theme.json");
    }
}
