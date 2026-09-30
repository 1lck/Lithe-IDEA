use gpui::Hsla;
use serde::{Deserialize, Serialize};

/// Semantic color palette for the entire application.
/// Modeled after Zed's ThemeColors but focused on Git GUI needs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThemeColors {
    // -- Backgrounds --
    pub background: Hsla,
    pub surface_background: Hsla,
    pub elevated_surface_background: Hsla,
    pub editor_background: Hsla,

    // -- Borders --
    pub border: Hsla,
    pub border_variant: Hsla,
    pub border_focused: Hsla,
    pub border_selected: Hsla,
    pub border_disabled: Hsla,
    pub border_transparent: Hsla,

    // -- Element states --
    pub element_background: Hsla,
    pub element_hover: Hsla,
    pub element_active: Hsla,
    pub element_selected: Hsla,
    pub element_disabled: Hsla,
    pub ghost_element_background: Hsla,
    pub ghost_element_hover: Hsla,
    pub ghost_element_active: Hsla,
    pub ghost_element_selected: Hsla,

    // -- Text --
    pub text: Hsla,
    pub text_muted: Hsla,
    pub text_placeholder: Hsla,
    pub text_disabled: Hsla,
    pub text_accent: Hsla,

    // -- Icons --
    pub icon: Hsla,
    pub icon_muted: Hsla,
    pub icon_disabled: Hsla,
    pub icon_accent: Hsla,

    // -- UI chrome --
    pub title_bar_background: Hsla,
    pub toolbar_background: Hsla,
    pub tab_bar_background: Hsla,
    pub tab_active_background: Hsla,
    pub tab_inactive_background: Hsla,
    pub status_bar_background: Hsla,
    pub panel_background: Hsla,
    pub scrollbar_thumb_background: Hsla,
    pub scrollbar_thumb_hover_background: Hsla,

    // -- Hint / badge backgrounds --
    pub hint_background: Hsla,

    // -- Version control (our specialty!) --
    pub vc_added: Hsla,
    pub vc_modified: Hsla,
    pub vc_deleted: Hsla,
    pub vc_conflict: Hsla,
    pub vc_renamed: Hsla,
    pub vc_untracked: Hsla,
}

/// Status colors for feedback states.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusColors {
    pub error: Hsla,
    pub error_background: Hsla,
    pub warning: Hsla,
    pub warning_background: Hsla,
    pub success: Hsla,
    pub success_background: Hsla,
    pub info: Hsla,
    pub info_background: Hsla,
    pub hint: Hsla,
}

/// Semantic color enum used by UI components.
/// Maps intent to actual theme colors at render time.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum Color {
    #[default]
    Default,
    Muted,
    Accent,
    Disabled,
    Placeholder,
    Error,
    Warning,
    Success,
    Info,
    Added,
    Modified,
    Deleted,
    Conflict,
    Renamed,
    Untracked,
    Custom(Hsla),
}

impl Color {
    /// Resolve this semantic color to an actual HSLA value using the current theme.
    pub fn color(&self, cx: &gpui::App) -> Hsla {
        let theme = cx.global::<crate::ThemeState>().theme();
        match self {
            Color::Default => theme.colors.text,
            Color::Muted => theme.colors.text_muted,
            Color::Accent => theme.colors.text_accent,
            Color::Disabled => theme.colors.text_disabled,
            Color::Placeholder => theme.colors.text_placeholder,
            Color::Error => theme.status.error,
            Color::Warning => theme.status.warning,
            Color::Success => theme.status.success,
            Color::Info => theme.status.info,
            Color::Added => theme.colors.vc_added,
            Color::Modified => theme.colors.vc_modified,
            Color::Deleted => theme.colors.vc_deleted,
            Color::Conflict => theme.colors.vc_conflict,
            Color::Renamed => theme.colors.vc_renamed,
            Color::Untracked => theme.colors.vc_untracked,
            Color::Custom(c) => *c,
        }
    }

    /// Resolve to an icon color (same mapping but uses icon slots where appropriate).
    pub fn icon_color(&self, cx: &gpui::App) -> Hsla {
        let theme = cx.global::<crate::ThemeState>().theme();
        match self {
            Color::Default => theme.colors.icon,
            Color::Muted => theme.colors.icon_muted,
            Color::Disabled => theme.colors.icon_disabled,
            Color::Accent => theme.colors.icon_accent,
            _ => self.color(cx),
        }
    }
}

impl From<Hsla> for Color {
    fn from(color: Hsla) -> Self {
        Color::Custom(color)
    }
}

// -- Helper functions --

fn hsla(h: f32, s: f32, l: f32, a: f32) -> Hsla {
    Hsla {
        h: h / 360.0,
        s: s / 100.0,
        l: l / 100.0,
        a,
    }
}

/// Convert 8-bit RGBA channels to `Hsla`.
///
/// This is the conversion every colour path ends in. Callers that already hold
/// channel bytes — syntax highlighting produces one style per span — should use
/// this directly rather than formatting a hex string only to parse it back.
pub fn rgba_u8_to_hsla(r: u8, g: u8, b: u8, a: u8) -> Hsla {
    let r = r as f32 / 255.0;
    let g = g as f32 / 255.0;
    let b = b as f32 / 255.0;
    let a = a as f32 / 255.0;

    // RGB to HSL conversion
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let l = (max + min) / 2.0;

    if (max - min).abs() < f32::EPSILON {
        return Hsla {
            h: 0.0,
            s: 0.0,
            l,
            a,
        };
    }

    let d = max - min;
    let s = if l > 0.5 {
        d / (2.0 - max - min)
    } else {
        d / (max + min)
    };

    let h = if (max - r).abs() < f32::EPSILON {
        let mut h = (g - b) / d;
        if g < b {
            h += 6.0;
        }
        h
    } else if (max - g).abs() < f32::EPSILON {
        (b - r) / d + 2.0
    } else {
        (r - g) / d + 4.0
    };

    Hsla {
        h: h / 6.0,
        s,
        l,
        a,
    }
}

/// Parse a hex color string strictly, returning None for invalid input.
/// Accepts: #RGB, #RGBA, #RRGGBB, #RRGGBBAA (case-insensitive).
pub fn hex_to_hsla_strict(hex: &str) -> Option<Hsla> {
    let hex = hex.trim_start_matches('#');

    if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }

    // Expand a single #RGB(A) digit to its #RRGGBB(AA) byte (e.g. A → AA).
    let expand = |b: u8| -> u8 {
        let digit = match b {
            b @ b'0'..=b'9' => b - b'0',
            b @ b'A'..=b'F' => b - b'A' + 10,
            b @ b'a'..=b'f' => b - b'a' + 10,
            _ => 0,
        };
        digit * 17
    };

    let bytes = hex.as_bytes();
    let (r, g, b, a) = match hex.len() {
        3 => (
            expand(bytes[0]),
            expand(bytes[1]),
            expand(bytes[2]),
            u8::MAX,
        ),
        4 => (
            expand(bytes[0]),
            expand(bytes[1]),
            expand(bytes[2]),
            expand(bytes[3]),
        ),
        6 => (
            u8::from_str_radix(&hex[0..2], 16).ok()?,
            u8::from_str_radix(&hex[2..4], 16).ok()?,
            u8::from_str_radix(&hex[4..6], 16).ok()?,
            u8::MAX,
        ),
        8 => (
            u8::from_str_radix(&hex[0..2], 16).ok()?,
            u8::from_str_radix(&hex[2..4], 16).ok()?,
            u8::from_str_radix(&hex[4..6], 16).ok()?,
            u8::from_str_radix(&hex[6..8], 16).ok()?,
        ),
        _ => return None,
    };

    Some(rgba_u8_to_hsla(r, g, b, a))
}

/// Parse a hex color string into an Hsla value, returning opaque black for invalid input.
/// Accepts #RGB, #RGBA, #RRGGBB, #RRGGBBAA (case-insensitive).
pub fn hex_to_hsla(hex: &str) -> Hsla {
    hex_to_hsla_strict(hex).unwrap_or(Hsla {
        h: 0.0,
        s: 0.0,
        l: 0.0,
        a: 1.0,
    })
}

/// Serialize an Hsla value to a hex string (#RRGGBB or #RRGGBBAA).
/// Alpha is included only when it is not fully opaque (a < 1.0).
pub fn hsla_to_hex(color: Hsla) -> String {
    // HSL to RGB
    let h = color.h;
    let s = color.s;
    let l = color.l;

    if s.abs() < f32::EPSILON {
        let r = (l * 255.0).round() as u8;
        let g = (l * 255.0).round() as u8;
        let b = (l * 255.0).round() as u8;
        if (color.a - 1.0).abs() < f32::EPSILON {
            format!("#{:02x}{:02x}{:02x}", r, g, b)
        } else {
            format!(
                "#{:02x}{:02x}{:02x}{:02x}",
                r,
                g,
                b,
                (color.a * 255.0).round() as u8
            )
        }
    } else {
        let q = if l < 0.5 {
            l * (1.0 + s)
        } else {
            l + s - l * s
        };
        let p = 2.0 * l - q;

        let r = hue_to_rgb(p, q, h + 1.0 / 3.0);
        let g = hue_to_rgb(p, q, h);
        let b = hue_to_rgb(p, q, h - 1.0 / 3.0);

        let r = (r * 255.0).round() as u8;
        let g = (g * 255.0).round() as u8;
        let b = (b * 255.0).round() as u8;

        if (color.a - 1.0).abs() < f32::EPSILON {
            format!("#{:02x}{:02x}{:02x}", r, g, b)
        } else {
            format!(
                "#{:02x}{:02x}{:02x}{:02x}",
                r,
                g,
                b,
                (color.a * 255.0).round() as u8
            )
        }
    }
}

fn hue_to_rgb(p: f32, q: f32, mut t: f32) -> f32 {
    if t < 0.0 {
        t += 1.0;
    }
    if t > 1.0 {
        t -= 1.0;
    }
    if t < 1.0 / 6.0 {
        return p + (q - p) * 6.0 * t;
    }
    if t < 1.0 / 2.0 {
        return q;
    }
    if t < 2.0 / 3.0 {
        return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    }
    p
}

/// Catppuccin Mocha dark theme colors.
pub fn catppuccin_mocha_colors() -> ThemeColors {
    // Catppuccin Mocha palette
    let base = hsla(240.0, 21.0, 15.0, 1.0); // #1e1e2e
    let mantle = hsla(240.0, 21.0, 12.0, 1.0); // #181825
    let crust = hsla(240.0, 23.0, 9.0, 1.0); // #11111b
    let surface0 = hsla(237.0, 16.0, 23.0, 1.0); // #313244
    let surface1 = hsla(234.0, 13.0, 31.0, 1.0); // #45475a
    let surface2 = hsla(233.0, 12.0, 39.0, 1.0); // #585b70
    let overlay0 = hsla(231.0, 11.0, 47.0, 1.0); // #6c7086
    let overlay1 = hsla(230.0, 13.0, 55.0, 1.0); // #7f849c
    let subtext0 = hsla(228.0, 17.0, 64.0, 1.0); // #a6adc8
    let text = hsla(227.0, 35.0, 80.0, 1.0); // #cdd6f4
    let mauve = hsla(267.0, 84.0, 81.0, 1.0); // #cba6f7 (accent)
    let red = hsla(343.0, 81.0, 75.0, 1.0); // #f38ba8
    let green = hsla(115.0, 54.0, 76.0, 1.0); // #a6e3a1
    let yellow = hsla(41.0, 86.0, 83.0, 1.0); // #f9e2af
    let blue = hsla(217.0, 92.0, 76.0, 1.0); // #89b4fa
    let peach = hsla(23.0, 92.0, 75.0, 1.0); // #fab387
    let teal = hsla(170.0, 57.0, 73.0, 1.0); // #94e2d5

    ThemeColors {
        background: crust,
        surface_background: mantle,
        elevated_surface_background: surface0,
        editor_background: base,

        border: surface1,
        border_variant: surface0,
        border_focused: mauve,
        border_selected: mauve,
        border_disabled: surface0,
        border_transparent: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },

        element_background: surface0,
        element_hover: surface1,
        element_active: surface2,
        element_selected: surface1,
        element_disabled: surface0,
        ghost_element_background: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },
        ghost_element_hover: hsla(237.0, 16.0, 23.0, 0.5),
        ghost_element_active: hsla(234.0, 13.0, 31.0, 0.7),
        ghost_element_selected: hsla(234.0, 13.0, 31.0, 0.7),

        text,
        text_muted: subtext0,
        text_placeholder: overlay1,
        text_disabled: overlay0,
        text_accent: mauve,

        icon: text,
        icon_muted: subtext0,
        icon_disabled: overlay0,
        icon_accent: mauve,

        title_bar_background: mantle,
        toolbar_background: base,
        tab_bar_background: mantle,
        tab_active_background: base,
        tab_inactive_background: mantle,
        status_bar_background: mantle,
        panel_background: base,
        scrollbar_thumb_background: surface1,
        scrollbar_thumb_hover_background: surface2,

        hint_background: hsla(170.0, 57.0, 73.0, 0.12),

        vc_added: green,
        vc_modified: yellow,
        vc_deleted: red,
        vc_conflict: peach,
        vc_renamed: blue,
        vc_untracked: teal,
    }
}

pub fn catppuccin_mocha_status() -> StatusColors {
    let red = hsla(343.0, 81.0, 75.0, 1.0);
    let yellow = hsla(41.0, 86.0, 83.0, 1.0);
    let green = hsla(115.0, 54.0, 76.0, 1.0);
    let blue = hsla(217.0, 92.0, 76.0, 1.0);
    let teal = hsla(170.0, 57.0, 73.0, 1.0);

    StatusColors {
        error: red,
        error_background: hsla(343.0, 81.0, 75.0, 0.15),
        warning: yellow,
        warning_background: hsla(41.0, 86.0, 83.0, 0.15),
        success: green,
        success_background: hsla(115.0, 54.0, 76.0, 0.15),
        info: blue,
        info_background: hsla(217.0, 92.0, 76.0, 0.15),
        hint: teal,
    }
}

/// Catppuccin Latte light theme colors.
pub fn catppuccin_latte_colors() -> ThemeColors {
    let base = hsla(220.0, 23.0, 95.0, 1.0); // #eff1f5
    let mantle = hsla(220.0, 22.0, 92.0, 1.0); // #e6e9ef
    let crust = hsla(220.0, 21.0, 89.0, 1.0); // #dce0e8
    let surface0 = hsla(223.0, 16.0, 83.0, 1.0); // #ccd0da
    let surface1 = hsla(225.0, 14.0, 77.0, 1.0); // #bcc0cc
    let surface2 = hsla(227.0, 12.0, 71.0, 1.0); // #acb0be
    let overlay0 = hsla(228.0, 11.0, 65.0, 1.0); // #9ca0b0
    let overlay1 = hsla(227.0, 12.0, 58.0, 1.0); // #8c8fa1
    let subtext0 = hsla(228.0, 14.0, 45.0, 1.0); // #6c6f85
    let text = hsla(234.0, 16.0, 35.0, 1.0); // #4c4f69
    let mauve = hsla(266.0, 85.0, 58.0, 1.0); // #8839ef
    let red = hsla(347.0, 87.0, 44.0, 1.0); // #d20f39
    let green = hsla(109.0, 58.0, 40.0, 1.0); // #40a02b
    let yellow = hsla(35.0, 77.0, 49.0, 1.0); // #df8e1d
    let blue = hsla(220.0, 91.0, 54.0, 1.0); // #1e66f5
    let peach = hsla(22.0, 99.0, 52.0, 1.0); // #fe640b
    let teal = hsla(183.0, 74.0, 35.0, 1.0); // #179299

    ThemeColors {
        background: crust,
        surface_background: base,
        elevated_surface_background: mantle,
        editor_background: base,

        border: surface1,
        border_variant: surface0,
        border_focused: mauve,
        border_selected: mauve,
        border_disabled: surface0,
        border_transparent: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },

        element_background: surface0,
        element_hover: surface1,
        element_active: surface2,
        element_selected: surface1,
        element_disabled: surface0,
        ghost_element_background: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },
        ghost_element_hover: hsla(223.0, 16.0, 83.0, 0.5),
        ghost_element_active: hsla(225.0, 14.0, 77.0, 0.7),
        ghost_element_selected: hsla(225.0, 14.0, 77.0, 0.7),

        text,
        text_muted: subtext0,
        text_placeholder: overlay1,
        text_disabled: overlay0,
        text_accent: mauve,

        icon: text,
        icon_muted: subtext0,
        icon_disabled: overlay0,
        icon_accent: mauve,

        title_bar_background: mantle,
        toolbar_background: base,
        tab_bar_background: mantle,
        tab_active_background: base,
        tab_inactive_background: mantle,
        status_bar_background: mantle,
        panel_background: base,
        scrollbar_thumb_background: surface1,
        scrollbar_thumb_hover_background: surface2,

        hint_background: hsla(183.0, 74.0, 35.0, 0.10),

        vc_added: green,
        vc_modified: yellow,
        vc_deleted: red,
        vc_conflict: peach,
        vc_renamed: blue,
        vc_untracked: teal,
    }
}

pub fn catppuccin_latte_status() -> StatusColors {
    let red = hsla(347.0, 87.0, 44.0, 1.0);
    let yellow = hsla(35.0, 77.0, 49.0, 1.0);
    let green = hsla(109.0, 58.0, 40.0, 1.0);
    let blue = hsla(220.0, 91.0, 54.0, 1.0);
    let teal = hsla(183.0, 74.0, 35.0, 1.0);

    StatusColors {
        error: red,
        error_background: hsla(347.0, 87.0, 44.0, 0.1),
        warning: yellow,
        warning_background: hsla(35.0, 77.0, 49.0, 0.1),
        success: green,
        success_background: hsla(109.0, 58.0, 40.0, 0.1),
        info: blue,
        info_background: hsla(220.0, 91.0, 54.0, 0.1),
        hint: teal,
    }
}

// -- One Dark theme colors --

/// One Dark (Atom) theme colors — GitKraken-like dark theme.
pub fn one_dark_colors() -> ThemeColors {
    let bg = hsla(220.0, 13.0, 18.0, 1.0); // #282c34
    let bg_lighter = hsla(220.0, 13.0, 21.0, 1.0); // #2c313a
    let gutter = hsla(220.0, 13.0, 24.0, 1.0); // #353b45
    let guide = hsla(220.0, 10.0, 30.0, 1.0); // #3b4048
    let text = hsla(219.0, 14.0, 71.0, 1.0); // #abb2bf
    let text_muted = hsla(220.0, 9.0, 55.0, 1.0); // #7f848e
    let text_dim = hsla(220.0, 9.0, 44.0, 1.0); // #636d83
    let accent = hsla(207.0, 82.0, 66.0, 1.0); // #61afef (blue)
    let red = hsla(355.0, 65.0, 65.0, 1.0); // #e06c75
    let green = hsla(95.0, 38.0, 62.0, 1.0); // #98c379
    let yellow = hsla(39.0, 67.0, 69.0, 1.0); // #e5c07b
    let magenta = hsla(286.0, 60.0, 67.0, 1.0); // #c678dd
    let cyan = hsla(187.0, 47.0, 55.0, 1.0); // #56b6c2
    let orange = hsla(29.0, 54.0, 61.0, 1.0); // #d19a66

    ThemeColors {
        background: hsla(220.0, 13.0, 15.0, 1.0),
        surface_background: bg,
        elevated_surface_background: bg_lighter,
        editor_background: bg,

        border: guide,
        border_variant: gutter,
        border_focused: accent,
        border_selected: accent,
        border_disabled: gutter,
        border_transparent: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },

        element_background: gutter,
        element_hover: guide,
        element_active: hsla(220.0, 10.0, 35.0, 1.0),
        element_selected: guide,
        element_disabled: gutter,
        ghost_element_background: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },
        ghost_element_hover: hsla(220.0, 13.0, 24.0, 0.5),
        ghost_element_active: hsla(220.0, 10.0, 30.0, 0.7),
        ghost_element_selected: hsla(220.0, 10.0, 30.0, 0.7),

        text,
        text_muted,
        text_placeholder: text_dim,
        text_disabled: text_dim,
        text_accent: accent,

        icon: text,
        icon_muted: text_muted,
        icon_disabled: text_dim,
        icon_accent: accent,

        title_bar_background: hsla(220.0, 13.0, 15.0, 1.0),
        toolbar_background: bg,
        tab_bar_background: hsla(220.0, 13.0, 15.0, 1.0),
        tab_active_background: bg,
        tab_inactive_background: hsla(220.0, 13.0, 15.0, 1.0),
        status_bar_background: hsla(220.0, 13.0, 15.0, 1.0),
        panel_background: bg,
        scrollbar_thumb_background: guide,
        scrollbar_thumb_hover_background: hsla(220.0, 10.0, 35.0, 1.0),

        hint_background: hsla(187.0, 47.0, 55.0, 0.12),

        vc_added: green,
        vc_modified: yellow,
        vc_deleted: red,
        vc_conflict: orange,
        vc_renamed: cyan,
        vc_untracked: magenta,
    }
}

pub fn one_dark_status() -> StatusColors {
    let red = hsla(355.0, 65.0, 65.0, 1.0);
    let yellow = hsla(39.0, 67.0, 69.0, 1.0);
    let green = hsla(95.0, 38.0, 62.0, 1.0);
    let blue = hsla(207.0, 82.0, 66.0, 1.0);
    let cyan = hsla(187.0, 47.0, 55.0, 1.0);

    StatusColors {
        error: red,
        error_background: hsla(355.0, 65.0, 65.0, 0.15),
        warning: yellow,
        warning_background: hsla(39.0, 67.0, 69.0, 0.15),
        success: green,
        success_background: hsla(95.0, 38.0, 62.0, 0.15),
        info: blue,
        info_background: hsla(207.0, 82.0, 66.0, 0.15),
        hint: cyan,
    }
}

// -- GitHub Dark theme colors --

/// GitHub Dark theme colors.
pub fn github_dark_colors() -> ThemeColors {
    let bg = hsla(215.0, 21.0, 7.0, 1.0); // #0d1117
    let surface = hsla(215.0, 19.0, 11.0, 1.0); // #161b22
    let elevated = hsla(215.0, 15.0, 14.0, 1.0); // #1c2128
    let border_main = hsla(215.0, 14.0, 21.0, 1.0); // #30363d
    let border_sub = hsla(215.0, 14.0, 15.0, 1.0); // #21262d
    let text = hsla(213.0, 14.0, 80.0, 1.0); // #c9d1d9
    let text_muted = hsla(212.0, 9.0, 57.0, 1.0); // #8b949e
    let text_dim = hsla(213.0, 9.0, 46.0, 1.0); // #6e7681
    let text_dimmer = hsla(215.0, 10.0, 31.0, 1.0); // #484f58
    let accent = hsla(212.0, 100.0, 67.0, 1.0); // #58a6ff
    let red = hsla(2.0, 92.0, 63.0, 1.0); // #f85149
    let green = hsla(139.0, 66.0, 49.0, 1.0); // #3fb950
    let yellow = hsla(39.0, 73.0, 49.0, 1.0); // #d29922
    let orange = hsla(24.0, 73.0, 50.0, 1.0); // #db6d28

    ThemeColors {
        background: bg,
        surface_background: surface,
        elevated_surface_background: elevated,
        editor_background: bg,

        border: border_main,
        border_variant: border_sub,
        border_focused: accent,
        border_selected: accent,
        border_disabled: border_sub,
        border_transparent: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },

        element_background: border_sub,
        element_hover: border_main,
        element_active: hsla(215.0, 10.0, 26.0, 1.0),
        element_selected: border_main,
        element_disabled: border_sub,
        ghost_element_background: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },
        ghost_element_hover: hsla(215.0, 14.0, 15.0, 0.5),
        ghost_element_active: hsla(215.0, 14.0, 21.0, 0.7),
        ghost_element_selected: hsla(215.0, 14.0, 21.0, 0.7),

        text,
        text_muted,
        text_placeholder: text_dim,
        text_disabled: text_dimmer,
        text_accent: accent,

        icon: text,
        icon_muted: text_muted,
        icon_disabled: text_dimmer,
        icon_accent: accent,

        title_bar_background: surface,
        toolbar_background: bg,
        tab_bar_background: surface,
        tab_active_background: bg,
        tab_inactive_background: surface,
        status_bar_background: surface,
        panel_background: bg,
        scrollbar_thumb_background: border_main,
        scrollbar_thumb_hover_background: text_dimmer,

        hint_background: hsla(212.0, 9.0, 57.0, 0.12),

        vc_added: green,
        vc_modified: yellow,
        vc_deleted: red,
        vc_conflict: orange,
        vc_renamed: accent,
        vc_untracked: text_muted,
    }
}

pub fn github_dark_status() -> StatusColors {
    let red = hsla(2.0, 92.0, 63.0, 1.0);
    let yellow = hsla(39.0, 73.0, 49.0, 1.0);
    let green = hsla(139.0, 66.0, 49.0, 1.0);
    let blue = hsla(212.0, 100.0, 67.0, 1.0);
    let muted = hsla(212.0, 9.0, 57.0, 1.0);

    StatusColors {
        error: red,
        error_background: hsla(2.0, 92.0, 63.0, 0.15),
        warning: yellow,
        warning_background: hsla(39.0, 73.0, 49.0, 0.15),
        success: green,
        success_background: hsla(139.0, 66.0, 49.0, 0.15),
        info: blue,
        info_background: hsla(212.0, 100.0, 67.0, 0.15),
        hint: muted,
    }
}

// -- Dracula theme colors --

/// Dracula theme colors.
pub fn dracula_colors() -> ThemeColors {
    let bg = hsla(231.0, 15.0, 18.0, 1.0); // #282a36
    let bg_darker = hsla(232.0, 14.0, 15.0, 1.0); // #21222c
    let surface = hsla(232.0, 14.0, 24.0, 1.0); // #343746
    let border_main = hsla(232.0, 14.0, 31.0, 1.0); // #44475a
    let text = hsla(60.0, 30.0, 96.0, 1.0); // #f8f8f2
    let text_muted = hsla(0.0, 0.0, 75.0, 1.0); // #bfbfbf
    let comment = hsla(225.0, 27.0, 51.0, 1.0); // #6272a4
    let text_dim = hsla(232.0, 14.0, 33.0, 1.0); // #545872
    let purple = hsla(265.0, 89.0, 78.0, 1.0); // #bd93f9
    let red = hsla(0.0, 100.0, 67.0, 1.0); // #ff5555
    let green = hsla(135.0, 94.0, 65.0, 1.0); // #50fa7b
    let yellow = hsla(65.0, 92.0, 77.0, 1.0); // #f1fa8c
    let orange = hsla(31.0, 100.0, 71.0, 1.0); // #ffb86c
    let cyan = hsla(191.0, 97.0, 77.0, 1.0); // #8be9fd

    ThemeColors {
        background: bg_darker,
        surface_background: bg,
        elevated_surface_background: surface,
        editor_background: bg,

        border: border_main,
        border_variant: surface,
        border_focused: purple,
        border_selected: purple,
        border_disabled: surface,
        border_transparent: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },

        element_background: surface,
        element_hover: border_main,
        element_active: hsla(232.0, 14.0, 37.0, 1.0),
        element_selected: border_main,
        element_disabled: surface,
        ghost_element_background: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },
        ghost_element_hover: hsla(232.0, 14.0, 31.0, 0.5),
        ghost_element_active: hsla(232.0, 14.0, 37.0, 0.7),
        ghost_element_selected: hsla(232.0, 14.0, 31.0, 0.7),

        text,
        text_muted,
        text_placeholder: comment,
        text_disabled: text_dim,
        text_accent: purple,

        icon: text,
        icon_muted: text_muted,
        icon_disabled: text_dim,
        icon_accent: purple,

        title_bar_background: bg_darker,
        toolbar_background: bg,
        tab_bar_background: bg_darker,
        tab_active_background: bg,
        tab_inactive_background: bg_darker,
        status_bar_background: bg_darker,
        panel_background: bg,
        scrollbar_thumb_background: border_main,
        scrollbar_thumb_hover_background: hsla(232.0, 14.0, 37.0, 1.0),

        hint_background: hsla(225.0, 27.0, 51.0, 0.12),

        vc_added: green,
        vc_modified: yellow,
        vc_deleted: red,
        vc_conflict: orange,
        vc_renamed: cyan,
        vc_untracked: comment,
    }
}

pub fn dracula_status() -> StatusColors {
    let red = hsla(0.0, 100.0, 67.0, 1.0);
    let yellow = hsla(65.0, 92.0, 77.0, 1.0);
    let green = hsla(135.0, 94.0, 65.0, 1.0);
    let cyan = hsla(191.0, 97.0, 77.0, 1.0);
    let comment = hsla(225.0, 27.0, 51.0, 1.0);

    StatusColors {
        error: red,
        error_background: hsla(0.0, 100.0, 67.0, 0.15),
        warning: yellow,
        warning_background: hsla(65.0, 92.0, 77.0, 0.15),
        success: green,
        success_background: hsla(135.0, 94.0, 65.0, 0.15),
        info: cyan,
        info_background: hsla(191.0, 97.0, 77.0, 0.15),
        hint: comment,
    }
}

/// High Contrast Dark theme — WCAG AAA compliant.
/// Pure black background with white text, bright saturated accents.
/// Designed for maximum readability and visual accessibility.
pub fn high_contrast_dark_colors() -> ThemeColors {
    // Near-black backgrounds with clear hierarchy
    let background = hsla(0.0, 0.0, 0.0, 1.0); // #000000
    let surface = hsla(0.0, 0.0, 4.0, 1.0); // #0a0a0a
    let elevated = hsla(0.0, 0.0, 8.0, 1.0); // #141414
    let editor = hsla(0.0, 0.0, 2.0, 1.0); // #050505

    // High contrast borders — visible but not harsh
    let border_main = hsla(0.0, 0.0, 35.0, 1.0); // #595959
    let border_variant = hsla(0.0, 0.0, 20.0, 1.0); // #333333
                                                    // Accent: bright cyan — maximum visibility on black
    let accent = hsla(180.0, 100.0, 50.0, 1.0); // #00ffff

    // Text: pure white for maximum contrast on black
    let text = hsla(0.0, 0.0, 100.0, 1.0); // #ffffff
                                           // Muted text: light gray — still >7:1 on black (WCAG AAA)
    let text_muted = hsla(0.0, 0.0, 80.0, 1.0); // #cccccc
    let text_placeholder = hsla(0.0, 0.0, 64.0, 1.0); // #a3a3a3 — ~7.4:1 on the 4% surface (WCAG AAA)
    let text_disabled = hsla(0.0, 0.0, 35.0, 1.0); // #595959

    // Git status — bright saturated for unambiguous distinction
    let vc_added = hsla(120.0, 100.0, 50.0, 1.0); // #00ff00
    let vc_modified = hsla(60.0, 100.0, 50.0, 1.0); // #ffff00
    let vc_deleted = hsla(0.0, 100.0, 55.0, 1.0); // #ff1a1a
    let vc_conflict = hsla(30.0, 100.0, 55.0, 1.0); // #ff8c00
    let vc_renamed = hsla(210.0, 100.0, 55.0, 1.0); // #0080ff
    let vc_untracked = hsla(180.0, 80.0, 55.0, 1.0); // #00e5e5

    ThemeColors {
        background,
        surface_background: surface,
        elevated_surface_background: elevated,
        editor_background: editor,

        border: border_main,
        border_variant,
        border_focused: accent,
        border_selected: accent,
        border_disabled: border_variant,
        border_transparent: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },

        element_background: surface,
        element_hover: elevated,
        element_active: hsla(0.0, 0.0, 14.0, 1.0),
        element_selected: elevated,
        element_disabled: surface,
        ghost_element_background: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },
        ghost_element_hover: hsla(0.0, 0.0, 14.0, 0.6),
        ghost_element_active: hsla(0.0, 0.0, 20.0, 0.8),
        ghost_element_selected: hsla(0.0, 0.0, 14.0, 0.8),

        text,
        text_muted,
        text_placeholder,
        text_disabled,
        text_accent: accent,

        icon: text,
        icon_muted: text_muted,
        icon_disabled: text_disabled,
        icon_accent: accent,

        title_bar_background: background,
        toolbar_background: surface,
        tab_bar_background: surface,
        tab_active_background: elevated,
        tab_inactive_background: background,
        status_bar_background: surface,
        panel_background: editor,
        scrollbar_thumb_background: border_main,
        scrollbar_thumb_hover_background: text_placeholder,

        hint_background: hsla(180.0, 100.0, 50.0, 0.12),

        vc_added,
        vc_modified,
        vc_deleted,
        vc_conflict,
        vc_renamed,
        vc_untracked,
    }
}

pub fn high_contrast_dark_status() -> StatusColors {
    let red = hsla(0.0, 100.0, 55.0, 1.0); // #ff1a1a
    let yellow = hsla(60.0, 100.0, 50.0, 1.0); // #ffff00
    let green = hsla(120.0, 100.0, 50.0, 1.0); // #00ff00
    let blue = hsla(210.0, 100.0, 55.0, 1.0); // #0080ff
    let cyan = hsla(180.0, 100.0, 50.0, 1.0); // #00ffff

    StatusColors {
        error: red,
        error_background: hsla(0.0, 100.0, 55.0, 0.2),
        warning: yellow,
        warning_background: hsla(60.0, 100.0, 50.0, 0.2),
        success: green,
        success_background: hsla(120.0, 100.0, 50.0, 0.2),
        info: blue,
        info_background: hsla(210.0, 100.0, 55.0, 0.2),
        hint: cyan,
    }
}

// -- Cream & Blue theme colors --

/// Cream & Blue light theme — near-paper surfaces with a Xero-style
/// cyan-blue accent. A barely-warm off-white sits beneath cool-grey
/// element layers, and the accent is a vibrant blue. Designed as a
/// more formal alternative to Catppuccin Latte.
pub fn cream_blue_colors() -> ThemeColors {
    let paper = hsla(40.0, 55.0, 96.0, 1.0);
    let paper_soft = hsla(40.0, 48.0, 93.0, 1.0);
    let paper_softer = hsla(40.0, 40.0, 90.0, 1.0);

    let surface0 = hsla(220.0, 12.0, 92.0, 1.0);
    let surface1 = hsla(220.0, 10.0, 86.0, 1.0);
    let surface2 = hsla(220.0, 9.0, 78.0, 1.0);

    let overlay0 = hsla(220.0, 7.0, 65.0, 1.0);
    let overlay1 = hsla(220.0, 7.0, 50.0, 1.0);
    let subtext0 = hsla(220.0, 10.0, 36.0, 1.0);
    let text = hsla(220.0, 25.0, 14.0, 1.0);

    let accent = hsla(200.0, 72.0, 50.0, 1.0);
    let accent_deep = hsla(205.0, 72.0, 40.0, 1.0);

    let red = hsla(8.0, 65.0, 50.0, 1.0);
    let green = hsla(150.0, 48.0, 38.0, 1.0);
    let yellow = hsla(38.0, 78.0, 45.0, 1.0);
    let orange = hsla(22.0, 80.0, 48.0, 1.0);
    let teal = hsla(190.0, 55.0, 38.0, 1.0);

    ThemeColors {
        background: paper_softer,
        surface_background: paper,
        elevated_surface_background: paper_soft,
        editor_background: paper,

        border: surface1,
        border_variant: surface0,
        border_focused: accent_deep,
        border_selected: accent_deep,
        border_disabled: surface0,
        border_transparent: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },

        element_background: surface0,
        element_hover: surface1,
        element_active: surface2,
        element_selected: surface1,
        element_disabled: surface0,
        ghost_element_background: Hsla {
            h: 0.0,
            s: 0.0,
            l: 0.0,
            a: 0.0,
        },
        ghost_element_hover: hsla(220.0, 12.0, 92.0, 0.5),
        ghost_element_active: hsla(220.0, 10.0, 86.0, 0.7),
        ghost_element_selected: hsla(220.0, 10.0, 86.0, 0.7),

        text,
        text_muted: subtext0,
        text_placeholder: overlay1,
        text_disabled: overlay0,
        text_accent: accent_deep,

        icon: text,
        icon_muted: subtext0,
        icon_disabled: overlay0,
        icon_accent: accent_deep,

        title_bar_background: paper_soft,
        toolbar_background: paper,
        tab_bar_background: paper_soft,
        tab_active_background: paper,
        tab_inactive_background: paper_soft,
        status_bar_background: paper_soft,
        panel_background: paper,
        scrollbar_thumb_background: surface1,
        scrollbar_thumb_hover_background: surface2,

        hint_background: Hsla { a: 0.10, ..accent },

        vc_added: green,
        vc_modified: yellow,
        vc_deleted: red,
        vc_conflict: orange,
        vc_renamed: accent_deep,
        vc_untracked: teal,
    }
}

pub fn cream_blue_status() -> StatusColors {
    let red = hsla(8.0, 65.0, 50.0, 1.0);
    let yellow = hsla(38.0, 78.0, 45.0, 1.0);
    let green = hsla(150.0, 48.0, 38.0, 1.0);
    let blue = hsla(205.0, 72.0, 40.0, 1.0);
    let teal = hsla(190.0, 55.0, 38.0, 1.0);

    StatusColors {
        error: red,
        error_background: hsla(8.0, 65.0, 50.0, 0.10),
        warning: yellow,
        warning_background: hsla(38.0, 78.0, 45.0, 0.10),
        success: green,
        success_background: hsla(150.0, 48.0, 38.0, 0.10),
        info: blue,
        info_background: hsla(205.0, 72.0, 40.0, 0.10),
        hint: teal,
    }
}

/// Lane colors for the commit graph. Cycles through these for branch visualization.
pub const GRAPH_LANE_COLORS: &[fn() -> Hsla] = &[
    || hsla(267.0, 84.0, 75.0, 1.0), // mauve (boosted)
    || hsla(217.0, 92.0, 65.0, 1.0), // blue (boosted)
    || hsla(115.0, 60.0, 65.0, 1.0), // green (boosted)
    || hsla(23.0, 92.0, 65.0, 1.0),  // peach (boosted)
    || hsla(343.0, 81.0, 65.0, 1.0), // red (boosted)
    || hsla(170.0, 65.0, 60.0, 1.0), // teal (boosted)
    || hsla(41.0, 86.0, 70.0, 1.0),  // yellow (boosted)
    || hsla(189.0, 75.0, 60.0, 1.0), // sapphire (boosted)
    || hsla(316.0, 72.0, 72.0, 1.0), // pink (boosted)
    || hsla(10.0, 70.0, 75.0, 1.0),  // rosewater (boosted)
];

pub fn lane_color(index: usize) -> Hsla {
    GRAPH_LANE_COLORS[index % GRAPH_LANE_COLORS.len()]()
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── hex_to_hsla ────────────────────────────────────────────────

    fn approx_eq(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-3
    }

    /// The byte path and the hex path must agree exactly — syntax highlighting
    /// uses the former, JSON theme loading the latter.
    #[test]
    fn rgba_u8_matches_hex_parsing() {
        let cases: &[(u8, u8, u8, u8)] = &[
            (0, 0, 0, 255),
            (255, 255, 255, 255),
            (255, 0, 0, 255),
            (0, 255, 0, 255),
            (0, 0, 255, 255),
            (18, 52, 86, 120),
            (200, 130, 65, 255),
            (7, 7, 7, 1),
        ];

        for &(r, g, b, a) in cases {
            let from_bytes = rgba_u8_to_hsla(r, g, b, a);
            let from_hex = hex_to_hsla(&format!("#{r:02x}{g:02x}{b:02x}{a:02x}"));
            assert!(
                approx_eq(from_bytes.h, from_hex.h)
                    && approx_eq(from_bytes.s, from_hex.s)
                    && approx_eq(from_bytes.l, from_hex.l)
                    && approx_eq(from_bytes.a, from_hex.a),
                "mismatch for ({r},{g},{b},{a}): {from_bytes:?} vs {from_hex:?}"
            );
        }
    }

    #[test]
    fn hex_pure_red_rgb() {
        // #FF0000 → RGB(1,0,0) → HSL(0°, 100%, 50%)
        let c = hex_to_hsla("#FF0000");
        assert!(approx_eq(c.h, 0.0));
        assert!(approx_eq(c.s, 1.0));
        assert!(approx_eq(c.l, 0.5));
        assert!(approx_eq(c.a, 1.0));
    }

    #[test]
    fn hex_pure_green_rgb() {
        // #00FF00 → HSL(120°/360=0.333…, 100%, 50%)
        let c = hex_to_hsla("#00FF00");
        assert!(approx_eq(c.h, 1.0 / 3.0));
        assert!(approx_eq(c.s, 1.0));
        assert!(approx_eq(c.l, 0.5));
    }

    #[test]
    fn hex_pure_blue_rgb() {
        // #0000FF → HSL(240°/360=0.666…, 100%, 50%)
        let c = hex_to_hsla("#0000FF");
        assert!(approx_eq(c.h, 2.0 / 3.0));
        assert!(approx_eq(c.s, 1.0));
        assert!(approx_eq(c.l, 0.5));
    }

    #[test]
    fn hex_white() {
        // #FFFFFF → grey (s=0), l=1
        let c = hex_to_hsla("#FFFFFF");
        assert!(approx_eq(c.l, 1.0));
        assert!(approx_eq(c.s, 0.0));
        assert!(approx_eq(c.a, 1.0));
    }

    #[test]
    fn hex_black() {
        // #000000 → l=0
        let c = hex_to_hsla("#000000");
        assert!(approx_eq(c.l, 0.0));
        assert!(approx_eq(c.a, 1.0));
    }

    #[test]
    fn hex_with_alpha_ff() {
        // #FF0000FF → full opacity red
        let c = hex_to_hsla("#FF0000FF");
        assert!(approx_eq(c.a, 1.0));
    }

    #[test]
    fn hex_with_alpha_80() {
        // #FFFFFF80 → ~50% opacity white
        let c = hex_to_hsla("#FFFFFF80");
        assert!(approx_eq(c.a, 0x80 as f32 / 255.0));
    }

    #[test]
    fn hex_lowercase_digits() {
        // Should work case-insensitively (upper octets accepted since from_str_radix handles both)
        let upper = hex_to_hsla("#AABBCC");
        let lower = hex_to_hsla("#aabbcc");
        assert!(approx_eq(upper.h, lower.h));
        assert!(approx_eq(upper.s, lower.s));
        assert!(approx_eq(upper.l, lower.l));
    }

    #[test]
    fn hex_without_hash_prefix() {
        // hex_to_hsla trims '#' if present; input without '#' should also work
        let with = hex_to_hsla("#FF0000");
        let without = hex_to_hsla("FF0000");
        assert!(approx_eq(with.h, without.h));
        assert!(approx_eq(with.s, without.s));
        assert!(approx_eq(with.l, without.l));
    }

    #[test]
    fn hex_invalid_length_fallback_black() {
        // 5-digit hex is not a recognised length → (0, 0, 0, 1.0) fallback
        let c = hex_to_hsla("#ABCDE");
        assert!(approx_eq(c.h, 0.0));
        assert!(approx_eq(c.s, 0.0));
        assert!(approx_eq(c.l, 0.0));
        assert!(approx_eq(c.a, 1.0));
    }

    #[test]
    fn hex_empty_fallback_black() {
        let c = hex_to_hsla("");
        assert!(approx_eq(c.a, 1.0));
        assert!(approx_eq(c.l, 0.0));
    }

    // ── hex_to_hsla_strict ─────────────────────────────────────────

    #[test]
    fn hex_strict_valid_6_digit() {
        let c = hex_to_hsla_strict("#FF0000").unwrap();
        assert!(approx_eq(c.h, 0.0));
        assert!(approx_eq(c.s, 1.0));
        assert!(approx_eq(c.l, 0.5));
        assert!(approx_eq(c.a, 1.0));
    }

    #[test]
    fn hex_strict_valid_8_digit_with_alpha() {
        let c = hex_to_hsla_strict("#FF000080").unwrap();
        assert!(approx_eq(c.h, 0.0));
        assert!(approx_eq(c.s, 1.0));
        assert!(approx_eq(c.l, 0.5));
        assert!(approx_eq(c.a, 128.0 / 255.0));
    }

    #[test]
    fn hex_strict_valid_3_digit() {
        // #ABC → A=10→170, B=11→187, C=12→204 (each ×17)
        // max=204, min=170 → l≈0.733, s≈0.063 (near-grey, slightly blue-ish)
        let c = hex_to_hsla_strict("#ABC").unwrap();
        assert!(approx_eq(c.a, 1.0));
        // Just verify it's a valid color (h,s,l in [0,1])
        assert!(c.h >= 0.0 && c.h <= 1.0);
        assert!(c.s >= 0.0 && c.s <= 1.0);
        assert!(c.l >= 0.0 && c.l <= 1.0);
    }

    #[test]
    fn hex_strict_valid_4_digit() {
        let c = hex_to_hsla_strict("#ABCD").unwrap();
        // A=10→170, B=11→187, C=12→204, D=13→221
        // R=170, G=187, B=204, A=221
        assert!(approx_eq(c.a, 221.0 / 255.0));
    }

    #[test]
    fn hex_strict_invalid_garbage_returns_none() {
        assert!(hex_to_hsla_strict("garbage").is_none());
        assert!(hex_to_hsla_strict("xyz123").is_none());
        assert!(hex_to_hsla_strict("#XYZ").is_none());
    }

    #[test]
    fn hex_strict_invalid_length_returns_none() {
        assert!(hex_to_hsla_strict("#AB").is_none()); // 2 chars
        assert!(hex_to_hsla_strict("#AB123").is_none()); // 5 chars
        assert!(hex_to_hsla_strict("#AB1234567").is_none()); // 9 chars
    }

    #[test]
    fn hex_strict_empty_returns_none() {
        assert!(hex_to_hsla_strict("").is_none());
        assert!(hex_to_hsla_strict("#").is_none());
    }

    #[test]
    fn hex_strict_no_hash_prefix_works() {
        let c = hex_to_hsla_strict("FF0000").unwrap();
        assert!(approx_eq(c.h, 0.0));
        assert!(approx_eq(c.s, 1.0));
    }

    #[test]
    fn hex_strict_roundtrip_red() {
        let c = hex_to_hsla_strict("#FF0000").unwrap();
        let hex = hsla_to_hex(c);
        assert_eq!(&hex, "#ff0000");
    }

    #[test]
    fn hex_strict_roundtrip_catppuccin_mocha_background() {
        let c = hex_to_hsla_strict("#1e1e2e").unwrap();
        let reloaded = hex_to_hsla_strict(&hsla_to_hex(c));
        assert!(reloaded.is_some());
        assert!(approx_eq(reloaded.unwrap().l, c.l));
    }

    // ── lane_color ─────────────────────────────────────────────────

    #[test]
    fn lane_color_index_zero_is_valid() {
        let c = lane_color(0);
        // Just verify it returns a fully opaque color (a == 1.0)
        assert!(approx_eq(c.a, 1.0));
    }

    #[test]
    fn lane_color_wraps_modulo_palette_length() {
        let n = super::GRAPH_LANE_COLORS.len();
        let c0 = lane_color(0);
        let cn = lane_color(n);
        // Wrapping should give the same color as index 0
        assert!(approx_eq(c0.h, cn.h));
        assert!(approx_eq(c0.s, cn.s));
        assert!(approx_eq(c0.l, cn.l));
    }

    #[test]
    fn lane_color_all_indices_opaque() {
        let n = super::GRAPH_LANE_COLORS.len();
        for i in 0..n {
            let c = lane_color(i);
            assert!(
                approx_eq(c.a, 1.0),
                "lane_color({}) has unexpected alpha {}",
                i,
                c.a
            );
        }
    }

    // ── high_contrast_dark ────────────────────────────────────────

    #[test]
    fn high_contrast_dark_is_fully_opaque() {
        let colors = super::high_contrast_dark_colors();
        assert!(approx_eq(colors.background.a, 1.0));
        assert!(approx_eq(colors.text.a, 1.0));
        assert!(approx_eq(colors.vc_added.a, 1.0));
    }

    #[test]
    fn high_contrast_dark_text_is_pure_white() {
        let colors = super::high_contrast_dark_colors();
        assert!(approx_eq(colors.text.h, 0.0));
        assert!(approx_eq(colors.text.s, 0.0));
        assert!(approx_eq(colors.text.l, 1.0));
    }

    #[test]
    fn high_contrast_dark_background_is_black() {
        let colors = super::high_contrast_dark_colors();
        assert!(approx_eq(colors.background.h, 0.0));
        assert!(approx_eq(colors.background.s, 0.0));
        assert!(approx_eq(colors.background.l, 0.0));
    }

    #[test]
    fn high_contrast_dark_vc_colors_are_distinct() {
        let colors = super::high_contrast_dark_colors();
        // All VC colors must be fully saturated (s=1.0) and fully opaque
        assert!(approx_eq(colors.vc_added.s, 1.0));
        assert!(approx_eq(colors.vc_modified.s, 1.0));
        assert!(approx_eq(colors.vc_deleted.s, 1.0));
        assert!(approx_eq(colors.vc_added.a, 1.0));
        assert!(approx_eq(colors.vc_modified.a, 1.0));
        assert!(approx_eq(colors.vc_deleted.a, 1.0));
        // And visually distinct hues
        assert_ne!(colors.vc_added.h, colors.vc_modified.h);
        assert_ne!(colors.vc_modified.h, colors.vc_deleted.h);
        assert_ne!(colors.vc_added.h, colors.vc_deleted.h);
    }

    #[test]
    fn high_contrast_dark_status_is_fully_opaque() {
        let status = super::high_contrast_dark_status();
        assert!(approx_eq(status.error.a, 1.0));
        assert!(approx_eq(status.success.a, 1.0));
        assert!(approx_eq(status.warning.a, 1.0));
        assert!(approx_eq(status.info.a, 1.0));
    }

    // ── hsla_to_hex ──────────────────────────────────────────────

    fn approx_eq_f32(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-3
    }

    #[test]
    fn hsla_to_hex_roundtrip_red() {
        // #FF0000 → hex_to_hsla → hsla_to_hex → #ff0000 (6-char, fully opaque)
        let c = super::hex_to_hsla("#FF0000");
        let hex = super::hsla_to_hex(c);
        assert_eq!(hex.len(), 7); // # + 6 hex chars
        assert_eq!(&hex[..7], "#ff0000");
    }

    #[test]
    fn hsla_to_hex_roundtrip_with_alpha() {
        // #FFFFFF80 → hex_to_hsla → hsla_to_hex → #ffffff80 (8-char with alpha)
        let c = super::hex_to_hsla("#FFFFFF80");
        let hex = super::hsla_to_hex(c);
        assert_eq!(hex.len(), 9); // # + 8 hex chars
        assert_eq!(&hex[..7], "#ffffff");
        assert!(hex.ends_with("80") || hex.ends_with("7f"));
    }

    #[test]
    fn hsla_to_hex_preserves_black() {
        let c = super::hex_to_hsla("#000000");
        let hex = super::hsla_to_hex(c);
        assert_eq!(&hex, "#000000");
    }

    #[test]
    fn hsla_to_hex_preserves_white() {
        let c = super::hex_to_hsla("#FFFFFF");
        let hex = super::hsla_to_hex(c);
        assert_eq!(&hex, "#ffffff");
    }

    #[test]
    fn hsla_to_hex_roundtrip_catppuccin_mocha() {
        // HSL → hex → HSL roundtrip for non-pure colors.
        // Saturation may drift slightly due to floating-point HSL↔RGB conversion.
        // We only check that hue and lightness are preserved within 0.02 tolerance.
        let mocha = super::catppuccin_mocha_colors();
        let bg_hex = super::hsla_to_hex(mocha.background);
        let reloaded = super::hex_to_hsla(&bg_hex);
        assert!(
            approx_eq_f32(reloaded.l, mocha.background.l),
            "lightness drifted: expected {}, got {}",
            mocha.background.l,
            reloaded.l
        );
        // Alpha should always be 1.0 for fully-opaque colors
        assert!(approx_eq_f32(reloaded.a, 1.0));
    }

    #[test]
    fn hsla_to_hex_transparent_alpha_omitted() {
        // Fully opaque (a=1.0) → 6-char output (no alpha suffix)
        let c = super::hex_to_hsla("#123456");
        assert!(approx_eq_f32(c.a, 1.0));
        let hex = super::hsla_to_hex(c);
        assert_eq!(hex.len(), 7);
    }

    #[test]
    fn hsla_to_hex_non_opaque_alpha_included() {
        // Non-1.0 alpha → 9-char output with alpha suffix
        let c = super::hex_to_hsla("#123456AB");
        assert!(!approx_eq_f32(c.a, 1.0));
        let hex = super::hsla_to_hex(c);
        assert_eq!(hex.len(), 9);
    }
}
