use alacritty_terminal::index::{Column, Line, Point as AlacPoint};
use alacritty_terminal::term::TermMode;
use gpui::{MouseButton, Pixels, Point};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectionType {
    Simple,
    Word,
    Line,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    pub start: AlacPoint,
    pub end: AlacPoint,
    pub selection_type: SelectionType,
}

impl Selection {
    pub fn new(start: AlacPoint, end: AlacPoint, selection_type: SelectionType) -> Self {
        Self {
            start,
            end,
            selection_type,
        }
    }

    pub fn contains(&self, point: AlacPoint) -> bool {
        let (start, end) = if self.start < self.end {
            (self.start, self.end)
        } else {
            (self.end, self.start)
        };

        point >= start && point <= end
    }
}

pub fn pixel_to_cell(
    position: Point<Pixels>,
    origin: Point<Pixels>,
    cell_width: Pixels,
    cell_height: Pixels,
) -> AlacPoint {
    let col = ((position.x - origin.x) / cell_width).floor();
    let col = col.max(0.0) as usize;

    let row = ((position.y - origin.y) / cell_height).floor();
    let row = row.max(0.0) as i32;

    AlacPoint::new(Line(row), Column(col))
}

pub fn selection_type_from_clicks(click_count: usize) -> SelectionType {
    match click_count {
        1 => SelectionType::Simple,
        2 => SelectionType::Word,
        _ => SelectionType::Line,
    }
}

pub fn mouse_button_report(
    button: MouseButton,
    pressed: bool,
    point: AlacPoint,
    modifiers: u8,
    mode: TermMode,
) -> Option<Vec<u8>> {
    if !mode
        .intersects(TermMode::MOUSE_REPORT_CLICK | TermMode::MOUSE_MOTION | TermMode::MOUSE_DRAG)
    {
        return None;
    }

    let button_code = match button {
        MouseButton::Left => 0,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
        _ => return None,
    };

    let button_value = button_code | modifiers;

    let col = point.column.0 + 1;
    let row = point.line.0 + 1;

    let action = if pressed { b'M' } else { b'm' };

    let sequence = format!("\x1b[<{};{};{}{}", button_value, col, row, action as char);
    Some(sequence.into_bytes())
}

pub fn scroll_report(
    delta: i32,
    point: AlacPoint,
    modifiers: u8,
    mode: TermMode,
) -> Option<Vec<u8>> {
    if mode.intersects(TermMode::MOUSE_REPORT_CLICK | TermMode::MOUSE_MOTION | TermMode::MOUSE_DRAG)
    {
        let button_code = if delta > 0 { 64 } else { 65 };
        let button_value = button_code | modifiers;

        let col = point.column.0 + 1;
        let row = point.line.0 + 1;

        let sequence = format!("\x1b[<{};{};{}M", button_value, col, row);
        return Some(sequence.into_bytes());
    }

    if mode.contains(TermMode::ALT_SCREEN) {
        return Some(scroll_to_arrow_keys(delta, mode));
    }

    None
}

fn scroll_to_arrow_keys(delta: i32, mode: TermMode) -> Vec<u8> {
    let count = delta.abs().min(5) as usize;

    let arrow_seq = if delta > 0 {
        if mode.contains(TermMode::APP_CURSOR) {
            b"\x1bOA"
        } else {
            b"\x1b[A"
        }
    } else {
        if mode.contains(TermMode::APP_CURSOR) {
            b"\x1bOB"
        } else {
            b"\x1b[B"
        }
    };

    let mut result = Vec::with_capacity(arrow_seq.len() * count);
    for _ in 0..count {
        result.extend_from_slice(arrow_seq);
    }
    result
}

pub fn encode_modifiers(shift: bool, alt: bool, control: bool) -> u8 {
    let mut modifiers = 0;
    if shift {
        modifiers |= 4;
    }
    if alt {
        modifiers |= 8;
    }
    if control {
        modifiers |= 16;
    }
    modifiers
}

pub fn pixels_to_scroll_lines(pixel_delta: Pixels, cell_height: Pixels) -> i32 {
    let lines = (pixel_delta / cell_height).round();
    lines.clamp(-10.0, 10.0) as i32
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{point, px};

    #[test]
    fn test_pixel_to_cell() {
        let position = point(px(100.0), px(50.0));
        let origin = point(px(10.0), px(10.0));
        let cell_width = px(10.0);
        let cell_height = px(20.0);

        let point = pixel_to_cell(position, origin, cell_width, cell_height);
        assert_eq!(point.column.0, 9);
        assert_eq!(point.line.0, 2);
    }

    #[test]
    fn test_pixel_to_cell_at_origin() {
        let position = point(px(10.0), px(10.0));
        let origin = point(px(10.0), px(10.0));
        let cell_width = px(10.0);
        let cell_height = px(20.0);

        let point = pixel_to_cell(position, origin, cell_width, cell_height);
        assert_eq!(point.column.0, 0);
        assert_eq!(point.line.0, 0);
    }

    #[test]
    fn test_pixel_to_cell_negative_coordinates() {
        let position = point(px(5.0), px(5.0));
        let origin = point(px(10.0), px(10.0));
        let cell_width = px(10.0);
        let cell_height = px(20.0);

        let point = pixel_to_cell(position, origin, cell_width, cell_height);
        assert_eq!(point.column.0, 0);
        assert_eq!(point.line.0, 0);
    }

    #[test]
    fn test_selection_type_from_clicks() {
        assert_eq!(selection_type_from_clicks(1), SelectionType::Simple);
        assert_eq!(selection_type_from_clicks(2), SelectionType::Word);
        assert_eq!(selection_type_from_clicks(3), SelectionType::Line);
        assert_eq!(selection_type_from_clicks(4), SelectionType::Line);
        assert_eq!(selection_type_from_clicks(10), SelectionType::Line);
    }

    #[test]
    fn test_selection_contains() {
        let selection = Selection::new(
            AlacPoint::new(Line(5), Column(10)),
            AlacPoint::new(Line(7), Column(20)),
            SelectionType::Simple,
        );

        assert!(selection.contains(AlacPoint::new(Line(6), Column(15))));

        assert!(selection.contains(AlacPoint::new(Line(5), Column(10))));
        assert!(selection.contains(AlacPoint::new(Line(7), Column(20))));

        assert!(!selection.contains(AlacPoint::new(Line(4), Column(15))));
        assert!(!selection.contains(AlacPoint::new(Line(8), Column(15))));
    }

    #[test]
    fn test_selection_contains_reverse() {
        let selection = Selection::new(
            AlacPoint::new(Line(7), Column(20)),
            AlacPoint::new(Line(5), Column(10)),
            SelectionType::Simple,
        );

        assert!(selection.contains(AlacPoint::new(Line(6), Column(15))));
        assert!(selection.contains(AlacPoint::new(Line(5), Column(10))));
        assert!(selection.contains(AlacPoint::new(Line(7), Column(20))));
    }

    #[test]
    fn test_mouse_button_report_left_click() {
        let point = AlacPoint::new(Line(5), Column(10));
        let mode = TermMode::MOUSE_REPORT_CLICK;

        let bytes = mouse_button_report(MouseButton::Left, true, point, 0, mode);
        assert!(bytes.is_some());

        let sequence = String::from_utf8(bytes.unwrap()).unwrap();
        assert_eq!(sequence, "\x1b[<0;11;6M");
    }

    #[test]
    fn test_mouse_button_report_right_release() {
        let point = AlacPoint::new(Line(0), Column(0));
        let mode = TermMode::MOUSE_REPORT_CLICK;

        let bytes = mouse_button_report(MouseButton::Right, false, point, 0, mode);
        assert!(bytes.is_some());

        let sequence = String::from_utf8(bytes.unwrap()).unwrap();
        assert_eq!(sequence, "\x1b[<2;1;1m");
    }

    #[test]
    fn test_mouse_button_report_with_modifiers() {
        let point = AlacPoint::new(Line(0), Column(0));
        let mode = TermMode::MOUSE_REPORT_CLICK;
        let modifiers = encode_modifiers(true, true, true);

        let bytes = mouse_button_report(MouseButton::Left, true, point, modifiers, mode);
        assert!(bytes.is_some());

        let sequence = String::from_utf8(bytes.unwrap()).unwrap();
        assert_eq!(sequence, "\x1b[<28;1;1M");
    }

    #[test]
    fn test_mouse_button_report_disabled() {
        let point = AlacPoint::new(Line(0), Column(0));
        let mode = TermMode::empty();

        let bytes = mouse_button_report(MouseButton::Left, true, point, 0, mode);
        assert!(bytes.is_none());
    }

    #[test]
    fn test_scroll_report_mouse_mode() {
        let point = AlacPoint::new(Line(5), Column(10));
        let mode = TermMode::MOUSE_REPORT_CLICK;

        let bytes = scroll_report(3, point, 0, mode);
        assert!(bytes.is_some());
        let sequence = String::from_utf8(bytes.unwrap()).unwrap();
        assert_eq!(sequence, "\x1b[<64;11;6M");

        let bytes = scroll_report(-2, point, 0, mode);
        assert!(bytes.is_some());
        let sequence = String::from_utf8(bytes.unwrap()).unwrap();
        assert_eq!(sequence, "\x1b[<65;11;6M");
    }

    #[test]
    fn test_scroll_report_alternate_screen() {
        let point = AlacPoint::new(Line(0), Column(0));
        let mode = TermMode::ALT_SCREEN;

        let bytes = scroll_report(3, point, 0, mode);
        assert!(bytes.is_some());
        let sequence = bytes.unwrap();
        assert_eq!(sequence, b"\x1b[A\x1b[A\x1b[A");
    }

    #[test]
    fn test_scroll_report_alternate_screen_app_cursor() {
        let point = AlacPoint::new(Line(0), Column(0));
        let mode = TermMode::ALT_SCREEN | TermMode::APP_CURSOR;

        let bytes = scroll_report(-2, point, 0, mode);
        assert!(bytes.is_some());
        let sequence = bytes.unwrap();
        assert_eq!(sequence, b"\x1bOB\x1bOB");
    }

    #[test]
    fn test_scroll_report_normal_screen() {
        let point = AlacPoint::new(Line(0), Column(0));
        let mode = TermMode::empty();

        let bytes = scroll_report(3, point, 0, mode);
        assert!(bytes.is_none());
    }

    #[test]
    fn test_encode_modifiers() {
        assert_eq!(encode_modifiers(false, false, false), 0);
        assert_eq!(encode_modifiers(true, false, false), 4);
        assert_eq!(encode_modifiers(false, true, false), 8);
        assert_eq!(encode_modifiers(false, false, true), 16);
        assert_eq!(encode_modifiers(true, true, false), 12);
        assert_eq!(encode_modifiers(true, false, true), 20);
        assert_eq!(encode_modifiers(false, true, true), 24);
        assert_eq!(encode_modifiers(true, true, true), 28);
    }

    #[test]
    fn test_pixels_to_scroll_lines() {
        let cell_height = px(20.0);

        assert_eq!(pixels_to_scroll_lines(px(60.0), cell_height), 3);
        assert_eq!(pixels_to_scroll_lines(px(-40.0), cell_height), -2);
        assert_eq!(pixels_to_scroll_lines(px(10.0), cell_height), 1);
        assert_eq!(pixels_to_scroll_lines(px(-10.0), cell_height), -1);

        assert_eq!(pixels_to_scroll_lines(px(300.0), cell_height), 10);
        assert_eq!(pixels_to_scroll_lines(px(-300.0), cell_height), -10);
    }

    #[test]
    fn test_scroll_to_arrow_keys_limit() {
        let mode = TermMode::empty();

        let bytes = scroll_to_arrow_keys(100, mode);
        let expected = b"\x1b[A\x1b[A\x1b[A\x1b[A\x1b[A";
        assert_eq!(bytes, expected);

        let bytes = scroll_to_arrow_keys(-100, mode);
        let expected = b"\x1b[B\x1b[B\x1b[B\x1b[B\x1b[B";
        assert_eq!(bytes, expected);
    }
}
