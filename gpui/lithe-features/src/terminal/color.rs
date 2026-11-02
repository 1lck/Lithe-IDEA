//! 终端 ANSI/VT 颜色转换。
//!
//! 将 `alacritty_terminal` 的 `Color` 解析并映射为 GPUI 的 `Hsla`，
//! 同时让默认前景色与背景色与 Lithe IDE 当前主题无缝融合。

use alacritty_terminal::vte::ansi::{Color, NamedColor, Rgb};
use gpui_kit::{Hsla, rgb};
use lithe_ui::LitheTokens;

/// 标准 16 色 ANSI 调色板（深色模式与浅色模式）。
const ANSI_DARK: [u32; 16] = [
    0x000000, // Black
    0xF0524F, // Red
    0x5C962C, // Green
    0xA68A0D, // Yellow
    0x3993D4, // Blue
    0xA771BF, // Magenta
    0x00A3A3, // Cyan
    0x808080, // White
    0x595959, // Bright Black
    0xFF4050, // Bright Red
    0x4FC414, // Bright Green
    0xE5BF00, // Bright Yellow
    0x1FB0FF, // Bright Blue
    0xED7EED, // Bright Magenta
    0x00E5E5, // Bright Cyan
    0xFFFFFF, // Bright White
];

const ANSI_LIGHT: [u32; 16] = [
    0x000000, // Black
    0xCE0505, // Red
    0x067D17, // Green
    0xB28C00, // Yellow
    0x063FDB, // Blue
    0xB309B3, // Magenta
    0x028E8E, // Cyan
    0x929292, // White
    0x656565, // Bright Black
    0xFF1616, // Bright Red
    0x16B42C, // Bright Green
    0xECC32C, // Bright Yellow
    0x2D61F0, // Bright Blue
    0xE617E6, // Bright Magenta
    0x15C1C1, // Bright Cyan
    0xC9C9C9, // Bright White
];

/// 将 `alacritty_terminal` 的 `Color` 转换为 GPUI 的 `Hsla`。
pub fn to_hsla(color: Color, is_background: bool, tokens: &LitheTokens, dark: bool) -> Hsla {
    match color {
        Color::Named(named) => named_to_hsla(named, is_background, tokens, dark),
        Color::Spec(Rgb { r, g, b }) => rgb_to_hsla(r, g, b),
        Color::Indexed(index) => indexed_to_hsla(index, dark),
    }
}

/// 命名颜色转 Hsla。
fn named_to_hsla(
    named: NamedColor,
    _is_background: bool,
    tokens: &LitheTokens,
    dark: bool,
) -> Hsla {
    let palette = if dark { ANSI_DARK } else { ANSI_LIGHT };
    match named {
        NamedColor::Foreground => tokens.primary_text,
        NamedColor::Background => tokens.editor,
        NamedColor::Cursor => tokens.accent,
        NamedColor::DimForeground => tokens.secondary_text,
        NamedColor::BrightForeground => tokens.primary_text,
        NamedColor::DimBlack => rgb(palette[0]).into(),
        NamedColor::DimRed => rgb(palette[1]).into(),
        NamedColor::DimGreen => rgb(palette[2]).into(),
        NamedColor::DimYellow => rgb(palette[3]).into(),
        NamedColor::DimBlue => rgb(palette[4]).into(),
        NamedColor::DimMagenta => rgb(palette[5]).into(),
        NamedColor::DimCyan => rgb(palette[6]).into(),
        NamedColor::DimWhite => rgb(palette[7]).into(),
        NamedColor::Black => rgb(palette[0]).into(),
        NamedColor::Red => rgb(palette[1]).into(),
        NamedColor::Green => rgb(palette[2]).into(),
        NamedColor::Yellow => rgb(palette[3]).into(),
        NamedColor::Blue => rgb(palette[4]).into(),
        NamedColor::Magenta => rgb(palette[5]).into(),
        NamedColor::Cyan => rgb(palette[6]).into(),
        NamedColor::White => rgb(palette[7]).into(),
        NamedColor::BrightBlack => rgb(palette[8]).into(),
        NamedColor::BrightRed => rgb(palette[9]).into(),
        NamedColor::BrightGreen => rgb(palette[10]).into(),
        NamedColor::BrightYellow => rgb(palette[11]).into(),
        NamedColor::BrightBlue => rgb(palette[12]).into(),
        NamedColor::BrightMagenta => rgb(palette[13]).into(),
        NamedColor::BrightCyan => rgb(palette[14]).into(),
        NamedColor::BrightWhite => rgb(palette[15]).into(),
    }
}

/// 256 色索引转 Hsla。
fn indexed_to_hsla(index: u8, dark: bool) -> Hsla {
    let palette = if dark { ANSI_DARK } else { ANSI_LIGHT };
    match index {
        0..=15 => rgb(palette[index as usize]).into(),
        // 16..231: 6x6x6 RGB cube
        16..=231 => {
            let index = index - 16;
            let r = (index / 36) % 6;
            let g = (index / 6) % 6;
            let b = index % 6;
            let step = |component: u8| -> u8 {
                if component == 0 {
                    0
                } else {
                    55 + component * 40
                }
            };
            rgb_to_hsla(step(r), step(g), step(b))
        }
        // 232..255: 24 阶灰阶
        232..=255 => {
            let gray = 8 + (index - 232) * 10;
            rgb_to_hsla(gray, gray, gray)
        }
    }
}

/// RGB 字节转 GPUI Hsla。
fn rgb_to_hsla(r: u8, g: u8, b: u8) -> Hsla {
    let hex = ((r as u32) << 16) | ((g as u32) << 8) | (b as u32);
    rgb(hex).into()
}
