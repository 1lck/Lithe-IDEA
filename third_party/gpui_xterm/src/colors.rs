use alacritty_terminal::term::color::Colors;
use alacritty_terminal::vte::ansi::{Color, NamedColor, Rgb};
use gpui::Hsla;

#[derive(Debug, Clone)]
pub struct ColorPalette {
    ansi_colors: [Hsla; 16],

    extended_colors: [Hsla; 256],

    foreground: Hsla,

    background: Hsla,

    cursor: Hsla,
}

impl Default for ColorPalette {
    fn default() -> Self {
        let ansi_colors = [
            rgb_to_hsla(Rgb {
                r: 0x00,
                g: 0x00,
                b: 0x00,
            }),
            rgb_to_hsla(Rgb {
                r: 0xcc,
                g: 0x00,
                b: 0x00,
            }),
            rgb_to_hsla(Rgb {
                r: 0x4e,
                g: 0x9a,
                b: 0x06,
            }),
            rgb_to_hsla(Rgb {
                r: 0xc4,
                g: 0xa0,
                b: 0x00,
            }),
            rgb_to_hsla(Rgb {
                r: 0x34,
                g: 0x65,
                b: 0xa4,
            }),
            rgb_to_hsla(Rgb {
                r: 0x75,
                g: 0x50,
                b: 0x7b,
            }),
            rgb_to_hsla(Rgb {
                r: 0x06,
                g: 0x98,
                b: 0x9a,
            }),
            rgb_to_hsla(Rgb {
                r: 0xd3,
                g: 0xd7,
                b: 0xcf,
            }),
            rgb_to_hsla(Rgb {
                r: 0x55,
                g: 0x57,
                b: 0x53,
            }),
            rgb_to_hsla(Rgb {
                r: 0xef,
                g: 0x29,
                b: 0x29,
            }),
            rgb_to_hsla(Rgb {
                r: 0x8a,
                g: 0xe2,
                b: 0x34,
            }),
            rgb_to_hsla(Rgb {
                r: 0xfc,
                g: 0xe9,
                b: 0x4f,
            }),
            rgb_to_hsla(Rgb {
                r: 0x72,
                g: 0x9f,
                b: 0xcf,
            }),
            rgb_to_hsla(Rgb {
                r: 0xad,
                g: 0x7f,
                b: 0xa8,
            }),
            rgb_to_hsla(Rgb {
                r: 0x34,
                g: 0xe2,
                b: 0xe2,
            }),
            rgb_to_hsla(Rgb {
                r: 0xee,
                g: 0xee,
                b: 0xec,
            }),
        ];

        let mut extended_colors = [Hsla::default(); 256];

        extended_colors[0..16].copy_from_slice(&ansi_colors);

        let mut idx = 16;
        for r in 0..6 {
            for g in 0..6 {
                for b in 0..6 {
                    let rgb = Rgb {
                        r: if r == 0 { 0 } else { 55 + r * 40 },
                        g: if g == 0 { 0 } else { 55 + g * 40 },
                        b: if b == 0 { 0 } else { 55 + b * 40 },
                    };
                    extended_colors[idx] = rgb_to_hsla(rgb);
                    idx += 1;
                }
            }
        }

        for i in 0..24 {
            let gray = (8 + i * 10) as u8;
            extended_colors[232 + i] = rgb_to_hsla(Rgb {
                r: gray,
                g: gray,
                b: gray,
            });
        }

        let foreground = rgb_to_hsla(Rgb {
            r: 0xd4,
            g: 0xd4,
            b: 0xd4,
        });
        let background = rgb_to_hsla(Rgb {
            r: 0x1e,
            g: 0x1e,
            b: 0x1e,
        });
        let cursor = rgb_to_hsla(Rgb {
            r: 0xff,
            g: 0xff,
            b: 0xff,
        });

        Self {
            ansi_colors,
            extended_colors,
            foreground,
            background,
            cursor,
        }
    }
}

impl ColorPalette {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn builder() -> ColorPaletteBuilder {
        ColorPaletteBuilder::new()
    }

    pub fn resolve(&self, color: Color, colors: &Colors) -> Hsla {
        match color {
            Color::Named(named) => {
                if let Some(rgb) = colors[named] {
                    return rgb_to_hsla(rgb);
                }

                let idx = named as usize;
                if idx < 16 {
                    self.ansi_colors[idx]
                } else {
                    match named {
                        NamedColor::Foreground => self.foreground,
                        NamedColor::Background => self.background,
                        NamedColor::Cursor => self.cursor,
                        NamedColor::DimForeground => {
                            let mut dim = self.foreground;
                            dim.l *= 0.7;
                            dim
                        }
                        NamedColor::BrightForeground => {
                            let mut bright = self.foreground;
                            bright.l = (bright.l * 1.2).min(1.0);
                            bright
                        }
                        NamedColor::DimBlack
                        | NamedColor::DimRed
                        | NamedColor::DimGreen
                        | NamedColor::DimYellow
                        | NamedColor::DimBlue
                        | NamedColor::DimMagenta
                        | NamedColor::DimCyan
                        | NamedColor::DimWhite => {
                            let base_idx = match named {
                                NamedColor::DimBlack => 0,
                                NamedColor::DimRed => 1,
                                NamedColor::DimGreen => 2,
                                NamedColor::DimYellow => 3,
                                NamedColor::DimBlue => 4,
                                NamedColor::DimMagenta => 5,
                                NamedColor::DimCyan => 6,
                                NamedColor::DimWhite => 7,
                                _ => 7,
                            };
                            let mut dim = self.ansi_colors[base_idx];
                            dim.l *= 0.7;
                            dim
                        }
                        _ => self.foreground,
                    }
                }
            }
            Color::Spec(rgb) => rgb_to_hsla(rgb),
            Color::Indexed(idx) => self.extended_colors[idx as usize],
        }
    }

    pub fn ansi_colors(&self) -> &[Hsla; 16] {
        &self.ansi_colors
    }

    pub fn extended_colors(&self) -> &[Hsla; 256] {
        &self.extended_colors
    }

    pub fn foreground(&self) -> Hsla {
        self.foreground
    }

    pub fn background(&self) -> Hsla {
        self.background
    }

    pub fn cursor(&self) -> Hsla {
        self.cursor
    }
}

fn rgb_to_hsla(rgb: Rgb) -> Hsla {
    let r = rgb.r as f32 / 255.0;
    let g = rgb.g as f32 / 255.0;
    let b = rgb.b as f32 / 255.0;

    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let delta = max - min;

    let l = (max + min) / 2.0;

    let s = if delta == 0.0 {
        0.0
    } else {
        delta / (1.0 - (2.0 * l - 1.0).abs())
    };

    let h = if delta == 0.0 {
        0.0
    } else if max == r {
        60.0 * (((g - b) / delta) % 6.0)
    } else if max == g {
        60.0 * (((b - r) / delta) + 2.0)
    } else {
        60.0 * (((r - g) / delta) + 4.0)
    };

    let h = if h < 0.0 { h + 360.0 } else { h } / 360.0;

    Hsla { h, s, l, a: 1.0 }
}

#[derive(Debug, Clone)]
pub struct ColorPaletteBuilder {
    palette: ColorPalette,
}

impl Default for ColorPaletteBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl ColorPaletteBuilder {
    pub fn new() -> Self {
        Self {
            palette: ColorPalette::default(),
        }
    }

    pub fn background(mut self, r: u8, g: u8, b: u8) -> Self {
        self.palette.background = rgb_to_hsla(Rgb { r, g, b });
        self
    }

    pub fn foreground(mut self, r: u8, g: u8, b: u8) -> Self {
        self.palette.foreground = rgb_to_hsla(Rgb { r, g, b });
        self
    }

    pub fn cursor(mut self, r: u8, g: u8, b: u8) -> Self {
        self.palette.cursor = rgb_to_hsla(Rgb { r, g, b });
        self
    }

    pub fn black(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(0, r, g, b);
        self
    }

    pub fn red(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(1, r, g, b);
        self
    }

    pub fn green(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(2, r, g, b);
        self
    }

    pub fn yellow(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(3, r, g, b);
        self
    }

    pub fn blue(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(4, r, g, b);
        self
    }

    pub fn magenta(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(5, r, g, b);
        self
    }

    pub fn cyan(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(6, r, g, b);
        self
    }

    pub fn white(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(7, r, g, b);
        self
    }

    pub fn bright_black(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(8, r, g, b);
        self
    }

    pub fn bright_red(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(9, r, g, b);
        self
    }

    pub fn bright_green(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(10, r, g, b);
        self
    }

    pub fn bright_yellow(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(11, r, g, b);
        self
    }

    pub fn bright_blue(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(12, r, g, b);
        self
    }

    pub fn bright_magenta(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(13, r, g, b);
        self
    }

    pub fn bright_cyan(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(14, r, g, b);
        self
    }

    pub fn bright_white(mut self, r: u8, g: u8, b: u8) -> Self {
        self.set_ansi_color(15, r, g, b);
        self
    }

    fn set_ansi_color(&mut self, idx: usize, r: u8, g: u8, b: u8) {
        let color = rgb_to_hsla(Rgb { r, g, b });
        self.palette.ansi_colors[idx] = color;
        self.palette.extended_colors[idx] = color;
    }

    pub fn build(self) -> ColorPalette {
        self.palette
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rgb_to_hsla_black() {
        let rgb = Rgb { r: 0, g: 0, b: 0 };
        let hsla = rgb_to_hsla(rgb);
        assert_eq!(hsla.l, 0.0);
        assert_eq!(hsla.s, 0.0);
        assert_eq!(hsla.a, 1.0);
    }

    #[test]
    fn test_rgb_to_hsla_white() {
        let rgb = Rgb {
            r: 255,
            g: 255,
            b: 255,
        };
        let hsla = rgb_to_hsla(rgb);
        assert_eq!(hsla.l, 1.0);
        assert_eq!(hsla.s, 0.0);
        assert_eq!(hsla.a, 1.0);
    }

    #[test]
    fn test_rgb_to_hsla_red() {
        let rgb = Rgb { r: 255, g: 0, b: 0 };
        let hsla = rgb_to_hsla(rgb);
        assert_eq!(hsla.h, 0.0);
        assert_eq!(hsla.s, 1.0);
        assert_eq!(hsla.a, 1.0);
    }

    #[test]
    fn test_color_palette_default() {
        let palette = ColorPalette::default();
        assert_eq!(palette.ansi_colors.len(), 16);
        assert_eq!(palette.extended_colors.len(), 256);
    }

    #[test]
    fn test_resolve_named_color() {
        use alacritty_terminal::vte::ansi::NamedColor;

        let palette = ColorPalette::new();
        let colors = Colors::default();
        let hsla = palette.resolve(Color::Named(NamedColor::Red), &colors);
        assert!(hsla.a > 0.0);
    }

    #[test]
    fn test_resolve_indexed_color() {
        let palette = ColorPalette::new();
        let colors = Colors::default();
        let hsla = palette.resolve(Color::Indexed(42), &colors);
        assert_eq!(hsla.a, 1.0);
    }

    #[test]
    fn test_resolve_spec_color() {
        let palette = ColorPalette::new();
        let colors = Colors::default();
        let rgb = Rgb {
            r: 128,
            g: 64,
            b: 192,
        };
        let hsla = palette.resolve(Color::Spec(rgb), &colors);
        assert_eq!(hsla.a, 1.0);
    }
}
