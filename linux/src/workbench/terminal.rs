//! Linux 原生 PTY 终端：`portable-pty` 跑 shell，`alacritty_terminal`
//!（Alacritty 网格）做真机解析与状态，键盘字符模式直输（对齐 IDEA
//! 内嵌终端的交互：历史、补全、方向键、中断均由 PTY 行规程处理）。
//!
//! 渲染取网格可见区，同样式字符合并展示；聚焦时在光标处画反色块。
//! 适配声明：多标签、新终端、终端内搜索、复制粘贴、滚到末尾跟随、
//! PTY 随窗缩放暂不支持（缺选择/滚动控制，采固定 120x30 跟随显示）。

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color as AlacColor, NamedColor, Processor, Rgb};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Context, FocusHandle, FontWeight, InteractiveElement as _, IntoElement, KeyDownEvent,
    ParentElement as _, Render, Rgba, StatefulInteractiveElement as _, Styled as _, Window,
};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::{Read, Write};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;

use crate::settings;
use crate::theme::ThemeColors;

/// PTY 固定尺寸（随窗缩放暂不支持）。
const TERMINAL_COLS: usize = 120;
const TERMINAL_ROWS: usize = 30;

/// 网格尺寸（`Term::new` 与 `resize` 共用）。
struct TermDims {
    cols: usize,
    rows: usize,
}

impl Dimensions for TermDims {
    fn total_lines(&self) -> usize {
        self.rows
    }

    fn screen_lines(&self) -> usize {
        self.rows
    }

    fn columns(&self) -> usize {
        self.cols
    }
}

/// xterm 基础 16 色。
const ANSI_PALETTE: [(u8, u8, u8); 16] = [
    (0, 0, 0),
    (205, 0, 0),
    (0, 205, 0),
    (205, 205, 0),
    (0, 0, 238),
    (205, 0, 205),
    (0, 205, 205),
    (229, 229, 229),
    (127, 127, 127),
    (255, 0, 0),
    (0, 255, 0),
    (255, 255, 0),
    (92, 92, 255),
    (255, 0, 255),
    (0, 255, 255),
    (255, 255, 255),
];

/// 256 色：0-15 基础色，16-231 立方体，232-255 灰阶。
fn palette_256(index: u8) -> (u8, u8, u8) {
    match index {
        0..=15 => ANSI_PALETTE[index as usize],
        16..=231 => {
            let n = index - 16;
            let levels = [0u8, 95, 135, 175, 215, 255];
            (
                levels[(n / 36) as usize],
                levels[((n % 36) / 6) as usize],
                levels[(n % 6) as usize],
            )
        }
        _ => {
            let v = 8 + (index - 232) * 10;
            (v, v, v)
        }
    }
}

fn rgba_of(rgb: (u8, u8, u8)) -> Rgba {
    Rgba {
        r: rgb.0 as f32 / 255.0,
        g: rgb.1 as f32 / 255.0,
        b: rgb.2 as f32 / 255.0,
        a: 1.0,
    }
}

/// 语义颜色解算：`Foreground`/`Background` 取主题，其余取调色板；
/// 加粗配 0-7 自动取高亮 variant（标准终端行为）。
fn resolve_color(color: AlacColor, bold: bool, default: Rgba) -> Rgba {
    match color {
        AlacColor::Named(NamedColor::Foreground) => default,
        AlacColor::Named(NamedColor::Background) => default,
        AlacColor::Named(named) => {
            let index = named as u8;
            let index = if bold && index < 8 { index + 8 } else { index };
            if index < 16 {
                rgba_of(ANSI_PALETTE[index as usize])
            } else {
                default
            }
        }
        AlacColor::Indexed(i) => rgba_of(palette_256(i)),
        AlacColor::Spec(Rgb { r, g, b }) => rgba_of((r, g, b)),
    }
}

/// Linux 原生 PTY 会话
pub struct TerminalSession {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    /// 主端句柄：必须活着，丢弃即关闭 PTY（shell 收 SIGHUP 退出）。
    #[allow(dead_code)]
    master: Arc<Mutex<Box<dyn portable_pty::MasterPty + Send>>>,
}

impl TerminalSession {
    /// 打开 PTY 会话并起输出线程：线程只透传原始字节块，主线程泵喂给
    /// 网格解析器（输出实时出现，对齐 xterm 的流式展示）。
    /// 返回会话、输出 channel 与展示用 shell 名。
    pub fn new(
        cols: u16,
        rows: u16,
        working_dir: &str,
        shell: &str,
    ) -> anyhow::Result<(Self, mpsc::Receiver<Vec<u8>>, String)> {
        let pty_system = native_pty_system();
        let pair = pty_system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let shell = if shell.trim().is_empty() {
            std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".to_string())
        } else {
            shell.to_string()
        };
        let mut cmd = CommandBuilder::new(&shell);
        cmd.cwd(working_dir);

        let _child = pair.slave.spawn_command(cmd)?;
        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let displayed_shell = shell.clone();

        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if tx.send(buf[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                }
            }
        });

        Ok((
            Self {
                writer: Arc::new(Mutex::new(writer)),
                master: Arc::new(Mutex::new(pair.master)),
            },
            rx,
            displayed_shell,
        ))
    }

    pub fn write_input(&self, input: &str) -> anyhow::Result<()> {
        self.write_bytes(input.as_bytes())
    }

    pub fn write_bytes(&self, bytes: &[u8]) -> anyhow::Result<()> {
        let mut writer = self.writer.lock().unwrap();
        writer.write_all(bytes)?;
        writer.flush()?;
        Ok(())
    }

    /// PTY 缩放（随窗缩放接入后调用，当前固定尺寸保留接口）。
    #[allow(dead_code)]
    pub fn resize(&self, cols: u16, rows: u16) {
        if let Ok(master) = self.master.lock() {
            let _ = master.resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            });
        }
    }
}

/// 终端视图组件：点击聚焦后键盘字符模式直输（IDEA 式交互）。
pub struct TerminalView {
    pub session: Option<TerminalSession>,
    pub working_dir: String,
    term: Term<VoidListener>,
    processor: Processor,
    focus_handle: FocusHandle,
}

impl TerminalView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            session: None,
            working_dir,
            term: Term::new(
                Config::default(),
                &TermDims {
                    cols: TERMINAL_COLS,
                    rows: TERMINAL_ROWS,
                },
                VoidListener,
            ),
            processor: Processor::new(),
            focus_handle: cx.focus_handle(),
        };
        view.attach_session(cx);
        view
    }

    /// 打开 PTY 会话并起主线程输出泵（channel 收字节块 → 网格解析 → notify）。
    fn attach_session(&mut self, cx: &mut Context<Self>) {
        let shell = Self::resolve_shell(cx);
        match TerminalSession::new(
            TERMINAL_COLS as u16,
            TERMINAL_ROWS as u16,
            &self.working_dir,
            &shell,
        ) {
            Ok((session, rx, displayed)) => {
                self.session = Some(session);
                let banner =
                    crate::i18n::menu_text(cx, "terminal.session").replace("{shell}", &displayed);
                // 首行提示直接画进网格（换行落行）。
                self.advance(format!("{banner}\r\n").as_bytes());
                Self::spawn_pump(rx, cx);
            }
            Err(_) => {
                self.session = None;
            }
        }
        cx.notify();
    }

    /// 网格推进（含借用拆分：解析器暂存取出再放回）。
    fn advance(&mut self, bytes: &[u8]) {
        let mut processor = std::mem::replace(&mut self.processor, Processor::new());
        processor.advance(&mut self.term, bytes);
        self.processor = processor;
    }

    /// 主线程输出泵：后台收字节块，回主线程喂网格解析器。
    fn spawn_pump(rx: mpsc::Receiver<Vec<u8>>, cx: &mut Context<Self>) {
        let rx = Arc::new(Mutex::new(rx));
        cx.spawn(async move |this, cx| loop {
            let slot = rx.clone();
            let next = cx
                .background_executor()
                .spawn(async move {
                    let guard = slot.lock().ok()?;
                    guard.recv().ok()
                })
                .await;
            match next {
                Some(bytes) => {
                    if this
                        .update(cx, |view, cx| {
                            view.advance(&bytes);
                            cx.notify();
                        })
                        .is_err()
                    {
                        break;
                    }
                }
                None => break,
            }
        })
        .detach();
    }

    /// 解析生效 shell：设置 `terminalDefaultShellId` 非空即用（名称经
    /// `PATH` 或 `/bin` 解析为路径），为空回退 `$SHELL`。
    fn resolve_shell(cx: &gpui_kit::App) -> String {
        let id = settings::get(cx)
            .terminal_default_shell_id
            .trim()
            .to_string();
        if id.is_empty() {
            return String::new();
        }
        if id.contains('/') {
            return id;
        }
        if let Some(paths) = std::env::var_os("PATH") {
            for dir in std::env::split_paths(&paths) {
                let candidate = dir.join(&id);
                if candidate.is_file() {
                    return candidate.to_string_lossy().to_string();
                }
            }
        }
        let fallback = format!("/bin/{id}");
        if std::path::Path::new(&fallback).is_file() {
            return fallback;
        }
        id
    }

    /// 程序化发送命令（宿主调用，如打开目录）：原文 + 换行。
    pub fn send_command(&mut self, cmd: &str, cx: &mut Context<Self>) {
        if let Some(session) = &self.session {
            let mut full = cmd.to_string();
            full.push('\n');
            let _ = session.write_input(&full);
        }
        cx.notify();
    }

    /// 清屏（等价于 shell `clear`：擦除可见区，保留回滚）。
    pub fn clear(&mut self, cx: &mut Context<Self>) {
        if self.session.is_some() {
            self.advance(b"\x1b[2J\x1b[H");
        }
        cx.notify();
    }

    /// 用现有工作目录重建 PTY 会话与网格（失败则置空并通知）。
    pub fn respawn(&mut self, cx: &mut Context<Self>) {
        self.session = None;
        self.term = Term::new(
            Config::default(),
            &TermDims {
                cols: TERMINAL_COLS,
                rows: TERMINAL_ROWS,
            },
            VoidListener,
        );
        self.processor = Processor::new();
        self.attach_session(cx);
    }

    /// 应用光标键模式：程序用 `\x1bO` 系，否则 `\x1b[` 系。
    fn cursor_key(&self, normal: &[u8], app: &[u8]) -> Vec<u8> {
        if self.term.mode().contains(TermMode::APP_CURSOR) {
            app.to_vec()
        } else {
            normal.to_vec()
        }
    }

    /// 键盘直输：可打印字符原样写 PTY，控制组合与功能键转义序列，
    /// 未知键放行（IDEA 快捷键不断）。返回是否消费。
    fn handle_key(&mut self, event: &KeyDownEvent) -> bool {
        let key = event.keystroke.key.as_str();
        let mods = &event.keystroke.modifiers;
        let bytes: Vec<u8> = if mods.control && !mods.alt && !mods.platform {
            // Ctrl+字母 → 控制字符（Ctrl+C 中断等）。
            let lower = key.to_lowercase();
            let mut chars = lower.chars();
            match (chars.next(), chars.next()) {
                (Some(c @ 'a'..='z'), None) => vec![(c as u8) - b'a' + 1],
                (Some(' '), None) => vec![0],
                (Some('['), None) => vec![0x1b],
                (Some('\\'), None) => vec![0x1c],
                (Some(']'), None) => vec![0x1d],
                (Some('^'), None) => vec![0x1e],
                (Some('_'), None) => vec![0x1f],
                _ => return false,
            }
        } else if mods.alt && !mods.control && !mods.platform {
            // Alt+字符 → ESC 前缀（readline Meta 键）。
            match &event.keystroke.key_char {
                Some(text) if text.chars().count() == 1 => {
                    let mut out = vec![0x1b];
                    out.extend_from_slice(text.as_bytes());
                    out
                }
                _ => return false,
            }
        } else if mods.control || mods.platform {
            return false;
        } else {
            match key {
                "enter" => b"\r".to_vec(),
                "backspace" => vec![0x7f],
                "tab" => b"\t".to_vec(),
                "escape" => vec![0x1b],
                "up" => self.cursor_key(b"\x1b[A", b"\x1bOA"),
                "down" => self.cursor_key(b"\x1b[B", b"\x1bOB"),
                "right" => self.cursor_key(b"\x1b[C", b"\x1bOC"),
                "left" => self.cursor_key(b"\x1b[D", b"\x1bOD"),
                "home" => self.cursor_key(b"\x1b[H", b"\x1bOH"),
                "end" => self.cursor_key(b"\x1b[F", b"\x1bOF"),
                "delete" => b"\x1b[3~".to_vec(),
                "pageup" => b"\x1b[5~".to_vec(),
                "pagedown" => b"\x1b[6~".to_vec(),
                "f1" => b"\x1bOP".to_vec(),
                "f2" => b"\x1bOQ".to_vec(),
                "f3" => b"\x1bOR".to_vec(),
                "f4" => b"\x1bOS".to_vec(),
                "f5" => b"\x1b[15~".to_vec(),
                "f6" => b"\x1b[17~".to_vec(),
                "f7" => b"\x1b[18~".to_vec(),
                "f8" => b"\x1b[19~".to_vec(),
                "f9" => b"\x1b[20~".to_vec(),
                "f10" => b"\x1b[21~".to_vec(),
                "f11" => b"\x1b[23~".to_vec(),
                "f12" => b"\x1b[24~".to_vec(),
                _ => match &event.keystroke.key_char {
                    // 可打印字符（含中文）原样直输。
                    Some(text) => text.as_bytes().to_vec(),
                    None => return false,
                },
            }
        };
        if let Some(session) = &self.session {
            let _ = session.write_bytes(&bytes);
        }
        true
    }
}

impl Render for TerminalView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let focused = self.focus_handle.is_focused(window);
        let default_fg = ThemeColors::foreground();
        let default_bg = ThemeColors::background();

        // 可见区按行分组（`display_iter` 即当前视口）。
        let content = self.term.renderable_content();
        let mut rows: Vec<(i32, Vec<(usize, char, AlacColor, AlacColor, bool)>)> = Vec::new();
        for indexed in content.display_iter {
            let line = indexed.point.line.0;
            let col = indexed.point.column.0;
            if rows.last().map(|(number, _)| *number) != Some(line) {
                rows.push((line, Vec::new()));
            }
            let cell = &indexed.cell;
            let inverse = cell.flags.contains(Flags::INVERSE);
            let (mut fg, mut bg) = (cell.fg, cell.bg);
            if inverse {
                std::mem::swap(&mut fg, &mut bg);
            }
            let bold = cell.flags.contains(Flags::BOLD);
            rows.last_mut()
                .expect("rows non-empty after push")
                .1
                .push((col, cell.c, fg, bg, bold));
        }
        let (cursor_line, cursor_col, cursor_visible) = (
            content.cursor.point.line.0,
            content.cursor.point.column.0,
            focused
                && !matches!(
                    content.cursor.shape,
                    alacritty_terminal::vte::ansi::CursorShape::Hidden
                ),
        );

        v_flex()
            .size_full()
            .bg(ThemeColors::background())
            .id("terminal-grid")
            .track_focus(&self.focus_handle)
            .cursor_text()
            .on_click(cx.listener(|this, _event, window, cx| {
                window.focus(&this.focus_handle, cx);
            }))
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                if this.handle_key(event) {
                    cx.stop_propagation();
                    cx.notify();
                }
            }))
            .child(
                // 输出网格（控制栏由底部窗格头负责，不再自带）。
                div()
                    .flex_1()
                    .w_full()
                    .min_h_0()
                    .overflow_y_scrollbar()
                    .p_2()
                    .text_xs()
                    .text_size(px(crate::settings::get(cx).terminal_font_size))
                    .font_family("monospace")
                    .children(rows.into_iter().map(|(line, cells)| {
                        render_term_row(
                            line,
                            &cells,
                            cursor_visible && line == cursor_line,
                            cursor_col,
                            default_fg,
                            default_bg,
                        )
                    })),
            )
    }
}

/// 渲染网格一行：同样式字符合并为一段；聚焦时在光标处画反色块。
fn render_term_row(
    line: i32,
    cells: &[(usize, char, AlacColor, AlacColor, bool)],
    cursor_here: bool,
    cursor_col: usize,
    default_fg: Rgba,
    default_bg: Rgba,
) -> gpui_kit::AnyElement {
    // 合并同样式段（宽字符占位格视为空格参与合并）。
    let mut spans: Vec<(AlacColor, AlacColor, bool, String)> = Vec::new();
    for (col, c, fg, bg, bold) in cells {
        let _ = col;
        let key = (*fg, *bg, *bold);
        if let Some((sfg, sbg, sbold, text)) = spans.last_mut() {
            if (*sfg, *sbg, *sbold) == key {
                text.push(*c);
                continue;
            }
        }
        spans.push((*fg, *bg, *bold, c.to_string()));
    }
    let total: usize = spans
        .iter()
        .map(|(_, _, _, text)| text.chars().count())
        .sum();
    // 光标超出文本末尾时在行尾补空格块。
    let trailing = cursor_here && cursor_col >= total;
    let mut row_el = h_flex()
        .id(format!("term-row-{line}"))
        .w_full()
        .items_center()
        .text_xs()
        .font_family("monospace");
    if spans.is_empty() && !trailing {
        return row_el
            .child(div().child(" ".to_string()))
            .into_any_element();
    }
    let mut col = 0;
    for (fg, bg, bold, text) in &spans {
        let fg_resolved = resolve_color(*fg, *bold, default_fg);
        let bg_resolved = resolve_color(*bg, false, default_bg);
        let chunk = |text: String| {
            div()
                .text_color(fg_resolved)
                .when(*bg != AlacColor::Named(NamedColor::Background), |el| {
                    el.bg(bg_resolved)
                })
                .when(*bold, |el| el.font_weight(FontWeight::BOLD))
                .child(text)
        };
        if trailing {
            row_el = row_el.child(chunk(text.clone()));
            continue;
        }
        let mut before = String::new();
        let mut cursor_char: Option<char> = None;
        let mut after = String::new();
        for c in text.chars() {
            if col < cursor_col {
                before.push(c);
            } else if cursor_char.is_none() {
                cursor_char = Some(c);
            } else {
                after.push(c);
            }
            col += 1;
        }
        if !before.is_empty() {
            row_el = row_el.child(chunk(before));
        }
        row_el = row_el.child(
            div()
                .text_color(default_bg)
                .bg(fg_resolved)
                .child(cursor_char.unwrap_or(' ').to_string()),
        );
        if !after.is_empty() {
            row_el = row_el.child(chunk(after));
        }
    }
    if trailing {
        row_el = row_el.child(
            div()
                .text_color(default_bg)
                .bg(default_fg)
                .child(" ".to_string()),
        );
    }
    row_el.into_any_element()
}
