//! 终端画布视图与渲染。
//!
//! 将 `TerminalModel` 中的字符单元格与光标绘制到 GPUI 画布上，
//! 并处理鼠标滚轮、点击聚焦与键盘事件。

use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::vte::ansi::CursorShape;
use gpui_kit::{
    AnyElement, BorderStyle, Bounds, Context, Corners, Edges, FocusHandle, Font, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, PaintQuad, ParentElement as _,
    Point as GpuiPoint, ScrollEvent, Styled as _, TextAlign, TextRun, canvas, div, point, px,
    transparent_black,
};
use lithe_ui::LitheTokens;

use super::color::to_hsla;
use super::keys;
use super::model::TerminalModel;

/// 渲染终端内容视图。
pub fn render_terminal_surface(
    model: &TerminalModel,
    focus_handle: &FocusHandle,
    font_size: f32,
    tokens: &LitheTokens,
    dark: bool,
    is_focused: bool,
    resize_sender: async_channel::Sender<(u16, u16)>,
    key_sender: async_channel::Sender<Vec<u8>>,
    scroll_sender: async_channel::Sender<i32>,
    cx: &mut Context<crate::terminal::TerminalPanel>,
) -> AnyElement {
    let content = model.renderable_content();
    let display_offset = content.display_offset;
    let cursor = content.cursor;
    let grid_cols = model.columns();
    let grid_lines = model.screen_lines();

    let font_size_px = px(font_size);
    let line_height_px = px((font_size * 1.35).ceil());

    // 预解析行内容
    let mut rows_cells: Vec<Vec<alacritty_terminal::term::cell::Cell>> =
        vec![vec![Default::default(); grid_cols]; grid_lines];

    for indexed in content.display_iter {
        let line = indexed.point.line.0;
        let screen_row = line + (display_offset as i32);
        if screen_row >= 0 && (screen_row as usize) < grid_lines {
            let col = indexed.point.column.0;
            if col < grid_cols {
                rows_cells[screen_row as usize][col] = indexed.cell.clone();
            }
        }
    }

    let default_bg = tokens.editor;
    let default_fg = tokens.primary_text;

    let font = Font {
        family: "JetBrains Mono".into(),
        weight: FontWeight::NORMAL,
        ..Default::default()
    };
    let bold_font = Font {
        family: "JetBrains Mono".into(),
        weight: FontWeight::BOLD,
        ..Default::default()
    };

    let copy_tokens = *tokens;
    let prepaint_font = font.clone();
    let on_key_sender = key_sender.clone();
    let on_scroll_sender = scroll_sender.clone();

    div()
        .id("terminal-native-view")
        .track_focus(focus_handle)
        .size_full()
        .bg(tokens.editor)
        .cursor_text()
        .on_mouse_down(
            gpui_kit::MouseButton::Left,
            cx.listener(|this, _, window, cx| {
                this.focus(window, cx);
            }),
        )
        .on_scroll(cx.listener(move |_this, event: &ScrollEvent, _window, cx| {
            let delta = match event.delta {
                gpui_kit::ScrollDelta::Lines(delta) => delta.y.round() as i32,
                gpui_kit::ScrollDelta::Pixels(delta) => (delta.y / px(16.0)).round() as i32,
            };
            if delta != 0 {
                let _ = on_scroll_sender.send_blocking(delta);
                cx.notify();
            }
        }))
        .on_key_down(cx.listener(move |_this, event: &KeyDownEvent, _window, cx| {
            if let Some(bytes) = keys::to_pty_bytes(event) {
                let _ = on_key_sender.send_blocking(bytes);
                cx.notify();
            }
        }))
        .child(canvas(
            // Prepaint: 检测容器真实大小并计算行列数
            move |bounds, window, _cx| {
                let padding_x = px(6.0);
                let padding_y = px(4.0);

                let available_w = (bounds.size.width - padding_x * 2.0).max(px(20.0));
                let available_h = (bounds.size.height - padding_y * 2.0).max(px(20.0));

                let test_run = TextRun {
                    len: 1,
                    font: prepaint_font.clone(),
                    color: default_fg,
                    background_color: None,
                    underline: None,
                    strikethrough: None,
                };
                let shaped = window.text_system().shape_line(
                    "M".into(),
                    font_size_px,
                    &[test_run],
                    None,
                );
                let cell_w = shaped.width.max(px(4.0));

                let cols = (available_w / cell_w).floor().max(10.0) as u16;
                let lines = (available_h / line_height_px).floor().max(2.0) as u16;

                if cols as usize != grid_cols || lines as usize != grid_lines {
                    let _ = resize_sender.send_blocking((cols, lines));
                }

                (cell_w, padding_x, padding_y)
            },
            // Paint: 绘制背景、行文本、光标
            move |bounds, (cell_w, padding_x, padding_y), window, cx| {
                // 1. 底色
                window.paint_quad(PaintQuad {
                    bounds,
                    background: default_bg.into(),
                    corner_radii: Corners::default(),
                    border_widths: Edges::default(),
                    border_color: transparent_black(),
                    border_style: BorderStyle::default(),
                });

                let origin_x = bounds.origin.x + padding_x;
                let origin_y = bounds.origin.y + padding_y;

                // 2. 逐行绘制
                for (row_idx, row) in rows_cells.iter().enumerate() {
                    let line_y = origin_y + line_height_px * (row_idx as f32);
                    if line_y > bounds.bottom() {
                        break;
                    }

                    let mut text_buf = String::with_capacity(grid_cols);
                    let mut runs: Vec<TextRun> = Vec::new();
                    let mut current_fg = default_fg;
                    let mut current_font = font.clone();

                    for (col_idx, cell) in row.iter().enumerate() {
                        let c = if cell.c == '\0' || cell.c == ' ' {
                            ' '
                        } else {
                            cell.c
                        };

                        let is_bold = cell.flags.contains(Flags::BOLD);
                        let is_inverse = cell.flags.contains(Flags::INVERSE);

                        let mut cell_fg = to_hsla(cell.fg, false, &copy_tokens, dark);
                        let mut cell_bg = if cell.bg == alacritty_terminal::vte::ansi::Color::Named(
                            alacritty_terminal::vte::ansi::NamedColor::Background,
                        ) {
                            None
                        } else {
                            Some(to_hsla(cell.bg, true, &copy_tokens, dark))
                        };

                        if is_inverse {
                            let temp_fg = cell_fg;
                            cell_fg = cell_bg.unwrap_or(default_bg);
                            cell_bg = Some(temp_fg);
                        }

                        // 如果单元格有自定义背景色，单独绘制背景矩形
                        if let Some(bg_color) = cell_bg {
                            let cell_bounds = Bounds {
                                origin: GpuiPoint {
                                    x: origin_x + cell_w * (col_idx as f32),
                                    y: line_y,
                                },
                                size: gpui_kit::Size {
                                    width: cell_w,
                                    height: line_height_px,
                                },
                            };
                            window.paint_quad(PaintQuad {
                                bounds: cell_bounds,
                                background: bg_color.into(),
                                corner_radii: Corners::default(),
                                border_widths: Edges::default(),
                                border_color: transparent_black(),
                                border_style: BorderStyle::default(),
                            });
                        }

                        let char_font = if is_bold {
                            bold_font.clone()
                        } else {
                            font.clone()
                        };

                        let char_bytes = c.len_utf8();
                        text_buf.push(c);

                        if runs.is_empty() {
                            runs.push(TextRun {
                                len: char_bytes,
                                font: char_font.clone(),
                                color: cell_fg,
                                background_color: None,
                                underline: None,
                                strikethrough: None,
                            });
                            current_fg = cell_fg;
                            current_font = char_font;
                        } else if current_fg == cell_fg && current_font == char_font {
                            runs.last_mut().unwrap().len += char_bytes;
                        } else {
                            runs.push(TextRun {
                                len: char_bytes,
                                font: char_font.clone(),
                                color: cell_fg,
                                background_color: None,
                                underline: None,
                                strikethrough: None,
                            });
                            current_fg = cell_fg;
                            current_font = char_font;
                        }
                    }

                    if !text_buf.trim().is_empty() {
                        let shaped_line = window.text_system().shape_line(
                            text_buf.into(),
                            font_size_px,
                            &runs,
                            None,
                        );
                        let _ = shaped_line.paint(
                            point(origin_x, line_y),
                            line_height_px,
                            TextAlign::Left,
                            None,
                            window,
                            cx,
                        );
                    }
                }

                // 3. 光标绘制
                if cursor.shape != CursorShape::Hidden {
                    let cursor_screen_line = cursor.point.line.0 + (display_offset as i32);
                    if cursor_screen_line >= 0 && (cursor_screen_line as usize) < grid_lines {
                        let cursor_col = cursor.point.column.0;
                        if cursor_col < grid_cols {
                            let cursor_x = origin_x + cell_w * (cursor_col as f32);
                            let cursor_y = origin_y + line_height_px * (cursor_screen_line as f32);
                            let cursor_color = if is_focused {
                                copy_tokens.accent
                            } else {
                                copy_tokens.secondary_text
                            };

                            match cursor.shape {
                                CursorShape::Block => {
                                    window.paint_quad(PaintQuad {
                                        bounds: Bounds {
                                            origin: point(cursor_x, cursor_y),
                                            size: gpui_kit::Size {
                                                width: cell_w,
                                                height: line_height_px,
                                            },
                                        },
                                        background: cursor_color.opacity(0.6).into(),
                                        corner_radii: Corners::default(),
                                        border_widths: Edges::default(),
                                        border_color: transparent_black(),
                                        border_style: BorderStyle::default(),
                                    });
                                }
                                CursorShape::Underline => {
                                    window.paint_quad(PaintQuad {
                                        bounds: Bounds {
                                            origin: point(
                                                cursor_x,
                                                cursor_y + line_height_px - px(2.0),
                                            ),
                                            size: gpui_kit::Size {
                                                width: cell_w,
                                                height: px(2.0),
                                            },
                                        },
                                        background: cursor_color.into(),
                                        corner_radii: Corners::default(),
                                        border_widths: Edges::default(),
                                        border_color: transparent_black(),
                                        border_style: BorderStyle::default(),
                                    });
                                }
                                CursorShape::Beam => {
                                    window.paint_quad(PaintQuad {
                                        bounds: Bounds {
                                            origin: point(cursor_x, cursor_y),
                                            size: gpui_kit::Size {
                                                width: px(2.0),
                                                height: line_height_px,
                                            },
                                        },
                                        background: cursor_color.into(),
                                        corner_radii: Corners::default(),
                                        border_widths: Edges::default(),
                                        border_color: transparent_black(),
                                        border_style: BorderStyle::default(),
                                    });
                                }
                                CursorShape::HollowBlock => {
                                    window.paint_quad(PaintQuad {
                                        bounds: Bounds {
                                            origin: point(cursor_x, cursor_y),
                                            size: gpui_kit::Size {
                                                width: cell_w,
                                                height: line_height_px,
                                            },
                                        },
                                        background: transparent_black().into(),
                                        corner_radii: Corners::default(),
                                        border_widths: Edges::all(px(1.0)),
                                        border_color: cursor_color,
                                        border_style: BorderStyle::Solid,
                                    });
                                }
                                _ => {}
                            }
                        }
                    }
                }
            },
        ))
        .into_any_element()
}
