//! 日志控制台的共享呈现：ANSI SGR 解析、可选择彩色行、平滑滚动与插入符。
//!
//! 运行面板和 Maven 输出面板共用这份实现：进程输出常带 SGR 转义序列，
//! GPUI 的纯文本元素会把它们当成普通字符，既不能着色也会破坏列宽；
//! 这里先把一行解析成「纯文本 + 颜色区间」，再用可选择文本元素绘制，
//! 复制与选择仍基于纯文本。

use std::ops::Range;
use std::rc::Rc;

use gpui_kit::base::{
    TextSelection, TextSelectionHandle, TextSelectionRegistration, TextSelectionRun,
};
use gpui_kit::component::scroll::Scrollbar;
use gpui_kit::component::{Theme, VirtualListScrollHandle};
use gpui_kit::{
    AnyElement, App, BorderStyle, Bounds, Context, Corners, Edges, Element, ElementId, FontWeight,
    GlobalElementId, HighlightStyle, Hitbox, HitboxBehavior, Hsla, InspectorElementId,
    InteractiveElement as _, IntoElement, LayoutId, MouseButton, MouseDownEvent, MouseMoveEvent,
    PaintQuad, ParentElement, Pixels, Point, ScrollEvent, ScrollStrategy, SharedString, Size,
    Styled, StyledText, TextStyleRefinement, Window, div, point, px, rgb, size, transparent_black,
};
use lithe_ui::LitheTokens;

const ESC: char = '\u{1b}';

/// ANSI 16 色前景调色板。取值与 macOS 控制台（IDEA 配色）保持一致。
#[derive(Clone, Copy, Debug)]
pub struct AnsiPalette {
    colors: [Hsla; 16],
}

impl AnsiPalette {
    pub fn new(dark: bool) -> Self {
        const DARK: [u32; 16] = [
            0x000000, 0xF0524F, 0x5C962C, 0xA68A0D, 0x3993D4, 0xA771BF, 0x00A3A3, 0x808080,
            0x595959, 0xFF4050, 0x4FC414, 0xE5BF00, 0x1FB0FF, 0xED7EED, 0x00E5E5, 0xFFFFFF,
        ];
        const LIGHT: [u32; 16] = [
            0x000000, 0xCE0505, 0x067D17, 0xB28C00, 0x063FDB, 0xB309B3, 0x028E8E, 0x929292,
            0x656565, 0xFF1616, 0x16B42C, 0xECC32C, 0x2D61F0, 0xE617E6, 0x15C1C1, 0xC9C9C9,
        ];
        let values = if dark { DARK } else { LIGHT };
        Self {
            colors: values.map(|value| rgb(value).into()),
        }
    }

    fn get(&self, index: usize) -> Hsla {
        self.colors[index.min(self.colors.len() - 1)]
    }
}

/// 制表位宽度，与浏览器 `<pre>` 的默认 `tab-size: 8` 一致。
pub const TAB_SIZE: usize = 8;

/// 把一行 Maven 输出解析成纯文本和颜色区间。
///
/// 除 SGR 颜色外的 CSI / OSC 序列（清行、光标、超链接等）直接丢弃，
/// 制表符按 8 列制表位展开为空格，其它控制字符忽略。
pub fn parse_line(
    raw: &str,
    palette: &AnsiPalette,
) -> (String, Vec<(Range<usize>, HighlightStyle)>) {
    if !raw.contains(ESC) && !raw.contains('\t') && !raw.chars().any(char::is_control) {
        return (raw.to_string(), Vec::new());
    }
    let mut plain = String::with_capacity(raw.len());
    let mut spans: Vec<(Range<usize>, HighlightStyle)> = Vec::new();
    let mut color: Option<Hsla> = None;
    let mut bold = false;
    let mut column = 0usize;
    let mut characters = raw.chars();

    while let Some(character) = characters.next() {
        if character != ESC {
            let start = plain.len();
            if character == '\t' {
                let spaces = TAB_SIZE - (column % TAB_SIZE);
                for _ in 0..spaces {
                    plain.push(' ');
                }
                column += spaces;
            } else if character.is_control() {
                continue;
            } else {
                plain.push(character);
                column += display_width(character);
            }
            let style = HighlightStyle {
                color,
                font_weight: bold.then_some(FontWeight::BOLD),
                ..Default::default()
            };
            if style.color.is_none() && style.font_weight.is_none() {
                continue;
            }
            if let Some((range, previous)) = spans.last_mut()
                && *previous == style
                && range.end == start
            {
                range.end = plain.len();
                continue;
            }
            spans.push((start..plain.len(), style));
            continue;
        }

        match characters.next() {
            Some('[') => {
                let mut parameters = String::new();
                let mut final_byte = None;
                for character in characters.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&character) {
                        final_byte = Some(character);
                        break;
                    }
                    parameters.push(character);
                }
                if final_byte == Some('m') {
                    apply_sgr(&parameters, palette, &mut color, &mut bold);
                }
            }
            Some(']') => {
                // OSC（例如 8;;url）：读到 BEL 或 ST 为止。
                let mut previous_was_escape = false;
                for character in characters.by_ref() {
                    if character == '\u{7}' || (previous_was_escape && character == '\\') {
                        break;
                    }
                    previous_was_escape = character == ESC;
                }
            }
            // 两字符转义（例如 ESC(0）直接跳过。
            _ => {}
        }
    }

    (plain, spans)
}

/// 等宽字体下字符占用的列数。东亚宽字符/全角字符占两列。
fn display_width(character: char) -> usize {
    match character as u32 {
        0x1100..=0x115F
        | 0x2E80..=0x303E
        | 0x3041..=0x33FF
        | 0x3400..=0x4DBF
        | 0x4E00..=0x9FFF
        | 0xA000..=0xA4CF
        | 0xAC00..=0xD7A3
        | 0xF900..=0xFAFF
        | 0xFE30..=0xFE6F
        | 0xFF00..=0xFF60
        | 0xFFE0..=0xFFE6
        | 0x1F300..=0x1F64F
        | 0x1F900..=0x1F9FF
        | 0x20000..=0x3FFFD => 2,
        _ => 1,
    }
}

/// 日志行的严重级别，用于给没有 SGR 颜色的输出按行着色。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnsiSeverity {
    Error,
    Warning,
    Info,
    Debug,
}

/// 识别行级严重级别：`[INFO]`、` WARN `、`ERROR:` 以及行首裸级别词。
///
/// 规则与 Tauri `run-output-style.ts` 的 `severityOfLine` 一致：级别词前必须
/// 是行首、空白或 `[`，后面必须跟 `]`、空白或 `:`。
pub fn severity_of_line(line: &str) -> Option<AnsiSeverity> {
    const WORDS: [(&str, AnsiSeverity); 8] = [
        ("WARNING", AnsiSeverity::Warning),
        ("SEVERE", AnsiSeverity::Error),
        ("ERROR", AnsiSeverity::Error),
        ("FATAL", AnsiSeverity::Error),
        ("WARN", AnsiSeverity::Warning),
        ("INFO", AnsiSeverity::Info),
        ("DEBUG", AnsiSeverity::Debug),
        ("TRACE", AnsiSeverity::Debug),
    ];

    let mut previous: Option<char> = None;
    for (index, character) in line.char_indices() {
        let boundary_before = previous.is_none_or(|value| value.is_whitespace() || value == '[');
        previous = Some(character);
        if !boundary_before {
            continue;
        }
        for (word, severity) in WORDS {
            let Some(rest) = line[index..].strip_prefix(word) else {
                continue;
            };
            let boundary = rest
                .chars()
                .next()
                .is_some_and(|next| next.is_whitespace() || next == ']' || next == ':');
            if boundary {
                return Some(severity);
            }
        }
    }
    None
}

/// 把行级严重级别的颜色填到 SGR 没有覆盖的区间。
pub fn overlay_severity(
    spans: Vec<(Range<usize>, HighlightStyle)>,
    length: usize,
    severity: AnsiSeverity,
    tokens: LitheTokens,
) -> Vec<(Range<usize>, HighlightStyle)> {
    if length == 0 {
        return spans;
    }
    let color = match severity {
        AnsiSeverity::Error => tokens.error,
        AnsiSeverity::Warning => tokens.warning,
        AnsiSeverity::Info => tokens.link,
        AnsiSeverity::Debug => tokens.secondary_text,
    };
    let style = HighlightStyle {
        color: Some(color),
        ..Default::default()
    };
    let mut result = Vec::with_capacity(spans.len() + 1);
    let mut cursor = 0;
    for (range, span_style) in spans {
        if cursor < range.start {
            result.push((cursor..range.start, style));
        }
        cursor = cursor.max(range.end);
        result.push((range, span_style));
    }
    if cursor < length {
        result.push((cursor..length, style));
    }
    result
}

fn apply_sgr(parameters: &str, palette: &AnsiPalette, color: &mut Option<Hsla>, bold: &mut bool) {
    let mut values: Vec<u32> = parameters
        .split(';')
        .map(|value| value.parse().unwrap_or(0))
        .collect();
    if values.is_empty() {
        values.push(0);
    }

    let mut index = 0;
    while index < values.len() {
        match values[index] {
            0 => {
                *color = None;
                *bold = false;
            }
            1 => *bold = true,
            22 => *bold = false,
            30..=37 => *color = Some(palette.get((values[index] - 30) as usize)),
            90..=97 => *color = Some(palette.get((values[index] - 90 + 8) as usize)),
            39 => *color = None,
            38 => {
                let (value, consumed) = extended_color(&values[index..], palette);
                if let Some(value) = value {
                    *color = Some(value);
                }
                index += consumed;
            }
            // 背景色与其它 SGR 不参与渲染：日志底色由面板主题决定。
            _ => {}
        }
        index += 1;
    }
}

/// 解析 `38;5;n` / `38;2;r;g;b`，返回颜色与额外消耗的参数个数。
fn extended_color(values: &[u32], palette: &AnsiPalette) -> (Option<Hsla>, usize) {
    match values.get(1) {
        Some(5) => match values.get(2) {
            Some(value) => (Some(color_256(*value, palette)), 2),
            None => (None, 1),
        },
        Some(2) => match (values.get(2), values.get(3), values.get(4)) {
            (Some(red), Some(green), Some(blue)) => (Some(rgb8(*red, *green, *blue)), 4),
            _ => (None, 1),
        },
        _ => (None, 1),
    }
}

fn color_256(value: u32, palette: &AnsiPalette) -> Hsla {
    if value < 16 {
        return palette.get(value as usize);
    }
    if value < 232 {
        let index = value - 16;
        let level = |component: u32| {
            if component == 0 {
                0
            } else {
                55 + component * 40
            }
        };
        return rgb8(level(index / 36), level((index % 36) / 6), level(index % 6));
    }
    let gray = 8 + (value - 232) * 10;
    rgb8(gray, gray, gray)
}

fn rgb8(red: u32, green: u32, blue: u32) -> Hsla {
    rgb((red.min(255) << 16) | (green.min(255) << 8) | blue.min(255)).into()
}

/// 一行可选择的富文本。元素行为与 `gpui_base::SelectableText` 一致，
/// 额外接受按字节区间着色的高亮，并可绘制/上报插入符位置。
pub struct AnsiSelectableText {
    id: ElementId,
    text: SharedString,
    text_style: TextStyleRefinement,
    styled_text: StyledText,
    document_order: u64,
    /// 本行插入符的字节偏移；`None` 表示插入符不在本行。
    caret: Option<usize>,
    /// 鼠标点击本行时上报点击处的字节偏移。
    on_caret: Option<Rc<dyn Fn(usize, &mut Window, &mut App) + 'static>>,
    /// 稳态逻辑选区区间；优先于虚拟化视口临时投影绘制，避免滚轮滚动时选区丢失。
    selected_range: Option<Range<usize>>,
    /// 鼠标按住拖拽经过本行时上报光标字符偏移。
    on_select_drag: Option<Rc<dyn Fn(usize, &mut Window, &mut App) + 'static>>,
}

impl AnsiSelectableText {
    pub fn new(
        id: impl Into<ElementId>,
        text: String,
        highlights: Vec<(Range<usize>, HighlightStyle)>,
        text_style: TextStyleRefinement,
    ) -> Self {
        let text: SharedString = text.into();
        let styled_text = if highlights.is_empty() {
            StyledText::new(text.clone())
        } else {
            StyledText::new(text.clone()).with_highlights(highlights)
        };
        Self {
            id: id.into(),
            text,
            text_style,
            styled_text,
            document_order: 0,
            caret: None,
            on_caret: None,
            selected_range: None,
            on_select_drag: None,
        }
    }

    /// 让同一面板的多行按阅读顺序参与复制。
    pub fn document_order(mut self, order: u64) -> Self {
        self.document_order = order;
        self
    }

    /// 在本行的 `offset` 字节处绘制插入符。
    pub fn caret(mut self, offset: usize) -> Self {
        self.caret = Some(offset);
        self
    }

    /// 设置本行要高亮绘制的稳定逻辑选区字节范围。
    pub fn selected_range(mut self, range: Option<Range<usize>>) -> Self {
        self.selected_range = range;
        self
    }

    /// 点击本行时上报点击处的字节偏移。
    pub fn on_caret(mut self, handler: impl Fn(usize, &mut Window, &mut App) + 'static) -> Self {
        self.on_caret = Some(Rc::new(handler));
        self
    }

    /// 按住鼠标拖拽经过本行时上报新的光标偏移。
    pub fn on_select_drag(
        mut self,
        handler: impl Fn(usize, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_select_drag = Some(Rc::new(handler));
        self
    }

    fn paint_selection(
        layout: &gpui_kit::TextLayout,
        range: Range<usize>,
        color: Hsla,
        window: &mut Window,
    ) {
        let (Some(start), Some(end)) = (
            layout.position_for_index(range.start),
            layout.position_for_index(range.end),
        ) else {
            return;
        };
        for bounds in selection_quad_bounds(start, end, layout.bounds(), layout.line_height()) {
            window.paint_quad(PaintQuad {
                bounds,
                background: color.into(),
                corner_radii: Corners::default(),
                border_widths: Edges::default(),
                border_color: transparent_black(),
                border_style: BorderStyle::default(),
            });
        }
    }
}

fn selection_quad_bounds(
    start: Point<Pixels>,
    end: Point<Pixels>,
    bounds: Bounds<Pixels>,
    line_height: Pixels,
) -> Vec<Bounds<Pixels>> {
    if start.y == end.y {
        return vec![Bounds::from_corners(
            start,
            Point::new(end.x, end.y + line_height),
        )];
    }

    let mut quads = vec![Bounds::from_corners(
        start,
        Point::new(bounds.right(), start.y + line_height),
    )];
    if end.y > start.y + line_height {
        quads.push(Bounds::from_corners(
            Point::new(bounds.left(), start.y + line_height),
            Point::new(bounds.right(), end.y),
        ));
    }
    quads.push(Bounds::from_corners(
        Point::new(bounds.left(), end.y),
        Point::new(end.x, end.y + line_height),
    ));
    quads
}

impl IntoElement for AnsiSelectableText {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for AnsiSelectableText {
    type RequestLayoutState = TextSelectionHandle;
    type PrepaintState = Hitbox;

    fn id(&self) -> Option<ElementId> {
        Some(self.id.clone())
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        global_id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let handle = window.with_element_state(
            global_id.expect("AnsiSelectableText must have a stable element id"),
            |retained: Option<TextSelectionHandle>, _| {
                let handle =
                    retained.unwrap_or_else(|| TextSelectionHandle::new(self.text.clone(), cx));
                (handle.clone(), handle)
            },
        );
        let (layout_id, ()) = window.with_text_style(Some(self.text_style.clone()), |window| {
            self.styled_text
                .request_layout(global_id, inspector_id, window, cx)
        });
        (layout_id, handle)
    }

    fn prepaint(
        &mut self,
        global_id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        handle: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        self.styled_text
            .prepaint(global_id, inspector_id, bounds, &mut (), window, cx);
        let hitbox = window.insert_hitbox(bounds, HitboxBehavior::Normal);
        let registration = TextSelectionRegistration::new(hitbox.clone(), bounds)
            .with_document_order(self.document_order)
            .with_text_bounds(vec![bounds])
            .with_rendered_element(handle, window, cx);
        handle.register(registration, window, cx);
        hitbox
    }

    fn paint(
        &mut self,
        global_id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        handle: &mut Self::RequestLayoutState,
        hitbox: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        if let Some(on_caret) = self.on_caret.clone() {
            let layout_for_click = self.styled_text.layout().clone();
            let hitbox_for_click = hitbox.clone();
            window.on_mouse_event(move |event: &MouseDownEvent, phase, window, cx| {
                // 在 capture 阶段先于文本选择处理，避免被选择逻辑提前消费；
                // 多击仍交给文本选择，这里只处理单击定位。
                if !phase.capture()
                    || event.button != MouseButton::Left
                    || event.click_count > 1
                    || !hitbox_for_click.bounds.contains(&event.position)
                {
                    return;
                }
                let offset = layout_for_click
                    .index_for_position(event.position)
                    .unwrap_or_else(|offset| offset);
                on_caret(offset, window, cx);
            });
        }
        if let Some(on_select_drag) = self.on_select_drag.clone() {
            let layout_for_drag = self.styled_text.layout().clone();
            let hitbox_for_drag = hitbox.clone();
            window.on_mouse_event(move |event: &MouseMoveEvent, phase, window, cx| {
                if !phase.bubble()
                    || event.pressed_button != Some(MouseButton::Left)
                    || !hitbox_for_drag.bounds.contains(&event.position)
                {
                    return;
                }
                let offset = layout_for_drag
                    .index_for_position(event.position)
                    .unwrap_or_else(|offset| offset);
                on_select_drag(offset, window, cx);
            });
        }
        let layout = self.styled_text.layout().clone();
        let selected_text_before = TextSelection::selected_text(window, cx);
        let projection = handle.update_runs(
            &[
                TextSelectionRun::new(self.text.clone(), layout.clone(), bounds)
                    .with_document_order(self.document_order),
            ],
            cx,
        );
        if selected_text_before != TextSelection::selected_text(window, cx) {
            window.refresh();
        }
        let color = Theme::global(cx).selection;
        if let Some(range) = self.selected_range.clone() {
            Self::paint_selection(&layout, range, color, window);
        } else {
            for range in projection.ranges().iter().flatten().cloned() {
                Self::paint_selection(&layout, range, color, window);
            }
        }
        self.styled_text.paint(
            global_id,
            inspector_id,
            bounds,
            &mut (),
            &mut (),
            window,
            cx,
        );
        // 插入符画在文本之上，避免被字形覆盖。
        if let Some(index) = self.caret
            && let Some(position) = layout.position_for_index(index)
        {
            window.paint_quad(PaintQuad {
                bounds: Bounds::new(position, size(px(1.5), layout.line_height())),
                background: Theme::global(cx).foreground.into(),
                corner_radii: Corners::default(),
                border_widths: Edges::default(),
                border_color: transparent_black(),
                border_style: BorderStyle::default(),
            });
        }
    }
}

/// 逻辑选区范围：起点与终点 (行号, 字节偏移)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConsoleSelection {
    pub anchor: (usize, usize),
    pub cursor: (usize, usize),
}

impl ConsoleSelection {
    pub fn new(anchor: (usize, usize), cursor: (usize, usize)) -> Self {
        Self { anchor, cursor }
    }

    pub fn normalized(&self) -> ((usize, usize), (usize, usize)) {
        if self.anchor <= self.cursor {
            (self.anchor, self.cursor)
        } else {
            (self.cursor, self.anchor)
        }
    }

    pub fn range_for_line(&self, line_index: usize, line_len: usize) -> Option<Range<usize>> {
        let ((start_line, start_col), (end_line, end_col)) = self.normalized();
        if line_index < start_line || line_index > end_line {
            return None;
        }
        if start_line == end_line {
            if start_col == end_col {
                return None;
            }
            let start = start_col.min(line_len);
            let end = end_col.min(line_len);
            return (start < end).then_some(start..end);
        }
        if line_index == start_line {
            let start = start_col.min(line_len);
            return (start < line_len).then_some(start..line_len);
        }
        if line_index == end_line {
            let end = end_col.min(line_len);
            return (end > 0).then_some(0..end);
        }
        Some(0..line_len)
    }
}

/// 面板把自身控制台状态交给共享滚动逻辑。
pub trait ConsoleHost: 'static {
    fn console(&mut self) -> &mut ConsoleScroll;
}

/// 控制台滚动与插入符状态。面板把它作为字段持有，渲染时与行数同步。
pub struct ConsoleScroll {
    /// 虚拟列表滚动句柄；面板渲染时 `track_scroll` 使用。
    pub handle: VirtualListScrollHandle,
    /// 虚拟列表每行尺寸，只随行数变化重建。
    pub item_sizes: Rc<Vec<Size<Pixels>>>,
    /// 已同步到列表的行数。
    pub line_count: usize,
    /// 插入符位置：行号与行内字节偏移。
    caret: Option<(usize, usize)>,
    /// 跨虚拟化视口稳定的逻辑选区，不随滚轮滚动丢失。
    pub selection: Option<ConsoleSelection>,
    pub is_selecting: bool,
}

impl ConsoleScroll {
    pub fn new() -> Self {
        Self {
            handle: VirtualListScrollHandle::new(),
            item_sizes: Rc::new(Vec::new()),
            line_count: 0,
            caret: None,
            selection: None,
            is_selecting: false,
        }
    }

    /// 清空行数据（切换会话/清空输出）；下一帧按实际行数重建。
    pub fn reset(&mut self) {
        self.line_count = 0;
        self.item_sizes = Rc::new(Vec::new());
        self.caret = None;
        self.selection = None;
        self.is_selecting = false;
        self.handle.set_offset(point(px(0.0), px(0.0)));
    }

    /// 丢弃行高缓存，但保留滚动句柄、插入符与选区。
    ///
    /// 切换软换行或控制台宽度变化后，旧的行高不再有效；下一帧按新的
    /// 换行结果重新测量。选区与插入符按逻辑行存储，不需要清空。
    pub fn invalidate_layout(&mut self) {
        self.line_count = 0;
        self.item_sizes = Rc::new(Vec::new());
    }

    /// 同步行数；返回行数是否变化。
    ///
    /// 行尺寸只随行数变化。追加输出时只在尾部扩展，避免每次都对整个
    /// 行高表做一次 O(n) 重建：大输出持续追加时，重建本身会成为帧耗时。
    pub fn sync_line_count(&mut self, line_count: usize, line_height: f32) -> bool {
        self.sync_line_count_with(line_count, |_| px(line_height))
    }

    /// 按行计算行高同步行数；软换行开启时每行可能占多行文本。
    ///
    /// 与 [`Self::sync_line_count`] 一样只在尾部扩展：`height` 只会为新
    /// 增的行调用，已测量的行高被复用。
    pub fn sync_line_count_with(
        &mut self,
        line_count: usize,
        mut height: impl FnMut(usize) -> Pixels,
    ) -> bool {
        if line_count == self.line_count {
            return false;
        }
        if line_count > self.line_count {
            let start = self.line_count;
            if let Some(sizes) = Rc::get_mut(&mut self.item_sizes) {
                sizes.reserve(line_count - start);
                for index in start..line_count {
                    sizes.push(size(px(0.0), height(index)));
                }
            } else {
                let mut sizes = (*self.item_sizes).clone();
                sizes.reserve(line_count - start);
                for index in start..line_count {
                    sizes.push(size(px(0.0), height(index)));
                }
                self.item_sizes = Rc::new(sizes);
            }
        } else {
            let mut sizes = (*self.item_sizes).clone();
            sizes.truncate(line_count);
            self.item_sizes = Rc::new(sizes);
        }
        self.line_count = line_count;
        true
    }

    pub fn scroll_to_item(&self, index: usize, strategy: ScrollStrategy) {
        self.handle.scroll_to_item(index, strategy);
    }

    /// 更新某一行的行高；最后一行还在追加时折行高度会随时间变化。
    pub fn set_line_height(&mut self, index: usize, height: Pixels) -> bool {
        let sizes = Rc::make_mut(&mut self.item_sizes);
        let Some(slot) = sizes.get_mut(index) else {
            return false;
        };
        if slot.height == height {
            return false;
        }
        let width = slot.width;
        *slot = size(width, height);
        true
    }

    /// 该行要绘制的插入符偏移。
    pub fn caret_for(&self, line: usize) -> Option<usize> {
        self.caret
            .filter(|(index, _)| *index == line)
            .map(|(_, offset)| offset)
    }

    /// 插入符快照，供渲染闭包按行查找。
    pub fn caret_snapshot(&self) -> Option<(usize, usize)> {
        self.caret
    }

    pub fn set_caret(&mut self, line: usize, offset: usize) {
        self.caret = Some((line, offset));
    }

    pub fn range_for_line(&self, line_index: usize, line_len: usize) -> Option<Range<usize>> {
        self.selection
            .as_ref()
            .and_then(|sel| sel.range_for_line(line_index, line_len))
    }

    pub fn has_selection(&self) -> bool {
        self.selection
            .as_ref()
            .is_some_and(|sel| sel.anchor != sel.cursor)
    }

    pub fn begin_selection(&mut self, line: usize, col: usize) {
        self.selection = Some(ConsoleSelection::new((line, col), (line, col)));
        self.is_selecting = true;
    }

    pub fn update_selection(&mut self, line: usize, col: usize) {
        if let Some(sel) = self.selection.as_mut() {
            sel.cursor = (line, col);
        }
    }

    pub fn end_selection(&mut self) {
        self.is_selecting = false;
        if let Some(sel) = self.selection {
            if sel.anchor == sel.cursor {
                self.selection = None;
            }
        }
    }

    /// 鼠标滚轮滚动时同步显示偏移。
    ///
    /// 虚拟列表内部的监听已经把 delta 写进滚动偏移，这里只需同步快照并请求
    /// 一次重绘。**不做逐帧插值**：插值会在每个动画帧重渲染整个面板，
    /// 大输出下反而让滚动明显卡顿；触控板等精确增量本身连续，原生滚动已经
    /// 足够平滑。
    pub fn on_scroll<T: ConsoleHost>(
        &mut self,
        _event: &ScrollEvent,
        _window: &mut Window,
        cx: &mut Context<T>,
    ) {
        // 只请求一次重绘：偏移已由虚拟列表写入，不需要再同步额外状态。
        cx.notify();
    }
}

impl Default for ConsoleScroll {
    fn default() -> Self {
        Self::new()
    }
}

/// 点击控制台一行时的插入符回调。
pub type ConsoleCaretHandler = Rc<dyn Fn(usize, &mut Window, &mut App) + 'static>;

/// 覆盖在控制台右侧的滚动条，可悬停显示并直接拖动。
pub fn console_scrollbar(handle: &VirtualListScrollHandle, id: &'static str) -> AnyElement {
    div()
        .absolute()
        .inset_0()
        .child(Scrollbar::vertical(handle).id(id))
        .into_any_element()
}

/// 构建控制台的一行：ANSI 颜色、行级 severity、插入符与稳态选区高亮。
pub fn console_line_element(
    id: String,
    index: usize,
    raw: &str,
    style: TextStyleRefinement,
    palette: &AnsiPalette,
    tokens: LitheTokens,
    caret: Option<usize>,
    on_caret: Option<ConsoleCaretHandler>,
    selected_range: Option<Range<usize>>,
    on_select_drag: Option<ConsoleCaretHandler>,
    line_height: f32,
) -> AnyElement {
    let element_id = SharedString::from(id);
    let (text, highlights) = parse_line(raw, palette);
    let highlights = match severity_of_line(&text) {
        Some(severity) => overlay_severity(highlights, text.len(), severity, tokens),
        None => highlights,
    };
    let mut element = AnsiSelectableText::new(element_id.clone(), text, highlights, style)
        .document_order(index as u64)
        .selected_range(selected_range);
    if let Some(handler) = on_caret {
        element = element.on_caret(move |offset, window, cx| handler(offset, window, cx));
    }
    if let Some(handler) = on_select_drag {
        element = element.on_select_drag(move |offset, window, cx| handler(offset, window, cx));
    }
    if let Some(offset) = caret {
        element = element.caret(offset);
    }
    div()
        .id(element_id)
        .w_full()
        .min_h(px(line_height))
        .flex_shrink_0()
        .child(element)
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn palette() -> AnsiPalette {
        AnsiPalette::new(true)
    }

    #[test]
    fn strips_escape_sequences_and_keeps_plain_text() {
        let (text, spans) = parse_line("\x1b[1;34mBuilding\x1b[0m project", &palette());
        assert_eq!(text, "Building project");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].0, 0..8);
        assert_eq!(spans[0].1.color, Some(palette().get(4)));
        assert_eq!(spans[0].1.font_weight, Some(FontWeight::BOLD));
    }

    #[test]
    fn leaves_lines_without_escapes_untouched() {
        let (text, spans) = parse_line("[INFO] module [jar]", &palette());
        assert_eq!(text, "[INFO] module [jar]");
        assert!(spans.is_empty());
    }

    #[test]
    fn parses_256_color_and_true_color() {
        let (_, spans) = parse_line("\x1b[38;5;196mred\x1b[0m", &palette());
        assert_eq!(spans[0].1.color, Some(color_256(196, &palette())));
        let (_, spans) = parse_line("\x1b[38;2;1;2;3mrgb\x1b[0m", &palette());
        assert_eq!(spans[0].1.color, Some(rgb8(1, 2, 3)));
    }

    #[test]
    fn drops_non_sgr_control_sequences() {
        let (text, spans) = parse_line("\x1b[2K\x1b[1mok\x1b[0m", &palette());
        assert_eq!(text, "ok");
        assert_eq!(spans.len(), 1);
    }

    #[test]
    fn expands_tabs_to_eight_column_stops() {
        let (text, spans) = parse_line("a\tb\tc", &palette());
        assert_eq!(text, format!("a{}b{}c", " ".repeat(7), " ".repeat(7)));
        assert!(spans.is_empty());
    }

    #[test]
    fn tab_width_uses_display_columns_for_wide_characters() {
        // “中”占两列：第 2 列后的 Tab 补到第 8 列。
        let (text, _) = parse_line("中\tb", &palette());
        assert_eq!(text, format!("中{}b", " ".repeat(6)));
    }

    #[test]
    fn drops_other_control_characters() {
        let (text, _) = parse_line("a\u{7}b\x08c", &palette());
        assert_eq!(text, "abc");
    }

    #[test]
    fn detects_log_severity_the_same_way_as_tauri() {
        assert_eq!(severity_of_line("[INFO] done"), Some(AnsiSeverity::Info));
        assert_eq!(
            severity_of_line("2026-01-01 [WARNING] slow"),
            Some(AnsiSeverity::Warning)
        );
        assert_eq!(severity_of_line("ERROR: boom"), Some(AnsiSeverity::Error));
        assert_eq!(
            severity_of_line("FATAL  crashed"),
            Some(AnsiSeverity::Error)
        );
        assert_eq!(severity_of_line("TRACE line"), Some(AnsiSeverity::Debug));
        assert_eq!(severity_of_line("INFORMATION only"), None);
        assert_eq!(severity_of_line("prefixINFO suffix"), None);
        // Tauri 的规则要求级别词后面还有 `]`、空白或 `:`，行尾不满足。
        assert_eq!(severity_of_line("[INFO"), None);
    }

    #[test]
    fn overlays_severity_only_onto_uncolored_regions() {
        let tokens = lithe_ui::LitheTokens::for_theme(lithe_ui::LitheThemeKind::Lithe, true);
        let spans = vec![(
            0..5,
            HighlightStyle {
                color: Some(palette().get(1)),
                ..Default::default()
            },
        )];
        let filled = overlay_severity(spans, 11, AnsiSeverity::Info, tokens);
        assert_eq!(filled.len(), 2);
        assert_eq!(filled[0].0, 0..5);
        assert_eq!(filled[0].1.color, Some(palette().get(1)));
        assert_eq!(filled[1].0, 5..11);
        assert_eq!(filled[1].1.color, Some(tokens.link));
    }
}
