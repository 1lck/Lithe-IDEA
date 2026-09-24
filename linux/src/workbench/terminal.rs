//! Linux 原生 PTY 终端：`portable-pty` 跑 shell，`vte`（Alacritty 解析器）
//! 做真机解析，键盘字符模式直输（对齐 IDEA 内嵌终端的交互：历史、
//! 补全、方向键、中断均由 PTY 行规程处理）。
//!
//! 显示模型为行式 + 样式段（非全网格）：处理打印 / 换行 / 回车覆盖 /
//! 退格 / SGR 颜色 / 擦除 / 光标移动；输出按行累积（上限丢弃最旧）。
//! 适配声明：多标签、新终端、终端内搜索、复制粘贴、全屏、滚到末尾跟随、
//! PTY 随窗缩放暂不支持（缺 xterm 级组件与滚动控制，采固定 120x30）。

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
use vte::{Parser, Perform};

use crate::settings;
use crate::theme::ThemeColors;

/// PTY 固定尺寸（随窗缩放暂不支持）。
const TERMINAL_COLS: usize = 120;
const TERMINAL_ROWS: u16 = 30;

/// 输出行数上限，超出丢弃最旧。
const MAX_TERMINAL_LINES: usize = 1000;

/// 渲染行数上限（样式段已合并，超出只保留末尾）。
const MAX_RENDER_LINES: usize = 600;

/// xterm 基础 16 色（加粗 0-7 自动取 8-15，标准终端行为）。
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

/// 语义颜色：默认色渲染时取主题，索引/RGB 取调色板。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
enum TermColor {
    #[default]
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct SpanStyle {
    fg: TermColor,
    bg: TermColor,
    bold: bool,
}

#[derive(Debug, Clone)]
struct StyledChar {
    c: char,
    style: SpanStyle,
}

/// 终端屏幕：行缓冲（末尾即当前行）+ 光标 + 当前样式 + 保存位。
struct TermScreen {
    lines: Vec<Vec<StyledChar>>,
    row: usize,
    col: usize,
    style: SpanStyle,
    saved: Option<(usize, usize)>,
}

impl TermScreen {
    fn new() -> Self {
        Self {
            lines: vec![Vec::new()],
            row: 0,
            col: 0,
            style: SpanStyle::default(),
            saved: None,
        }
    }

    fn clear_all(&mut self) {
        self.lines = vec![Vec::new()];
        self.row = 0;
        self.col = 0;
        self.style = SpanStyle::default();
    }

    /// 保证 `row` 行存在，返回其可变引用（行号超限自动补空行）。
    fn row_mut(&mut self, row: usize) -> &mut Vec<StyledChar> {
        while self.lines.len() <= row {
            self.lines.push(Vec::new());
        }
        &mut self.lines[row]
    }

    /// 换行：光标移到下一行行首，超限丢弃最旧行。
    fn newline(&mut self) {
        self.row += 1;
        self.col = 0;
        self.row_mut(self.row);
        if self.lines.len() > MAX_TERMINAL_LINES {
            let overflow = self.lines.len() - MAX_TERMINAL_LINES;
            self.lines.drain(..overflow);
            self.row = self.row.saturating_sub(overflow);
        }
    }

    /// 在光标处打印字符（覆盖写，超宽自动换行）。
    fn put_char(&mut self, c: char) {
        if self.col >= TERMINAL_COLS {
            self.newline();
        }
        let style = self.style;
        let col = self.col;
        let row = self.row;
        let line = self.row_mut(row);
        if col < line.len() {
            line[col] = StyledChar { c, style };
        } else {
            while line.len() < col {
                line.push(StyledChar {
                    c: ' ',
                    style: SpanStyle::default(),
                });
            }
            line.push(StyledChar { c, style });
        }
        self.col += 1;
    }
}

/// 取第 `index` 个参数（无参回退 `default`）。
fn csi_param(params: &vte::Params, index: usize, default: u16) -> u16 {
    params
        .iter()
        .flat_map(|group| group.iter().copied())
        .nth(index)
        .unwrap_or(default)
}

impl Perform for TermScreen {
    fn print(&mut self, c: char) {
        self.put_char(c);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            b'\n' | b'\x0b' | b'\x0c' => self.newline(),
            b'\r' => self.col = 0,
            // 退格：只回退不删除（覆盖写模型）。
            0x08 => self.col = self.col.saturating_sub(1),
            // 制表：到下一个 8 列停靠位。
            b'\t' => self.col = (self.col + 8) & !7,
            // BEL 等其余控制字符忽略。
            _ => {}
        }
    }

    fn csi_dispatch(
        &mut self,
        params: &vte::Params,
        _intermediates: &[u8],
        _ignore: bool,
        action: char,
    ) {
        match action {
            // 光标移动
            'A' => self.row = self.row.saturating_sub(csi_param(params, 0, 1) as usize),
            'B' => {
                let row = self.row + csi_param(params, 0, 1) as usize;
                self.row = row;
                self.row_mut(row);
            }
            'C' => self.col += csi_param(params, 0, 1) as usize,
            'D' => self.col = self.col.saturating_sub(csi_param(params, 0, 1) as usize),
            'E' => {
                self.row += csi_param(params, 0, 1) as usize;
                self.col = 0;
                let row = self.row;
                self.row_mut(row);
            }
            'F' => {
                self.row = self.row.saturating_sub(csi_param(params, 0, 1) as usize);
                self.col = 0;
            }
            'G' => self.col = csi_param(params, 0, 1).saturating_sub(1) as usize,
            'H' | 'f' => {
                self.row = csi_param(params, 0, 1).saturating_sub(1) as usize;
                self.col = csi_param(params, 1, 1).saturating_sub(1) as usize;
                let row = self.row;
                self.row_mut(row);
            }
            // 擦除显示
            'J' => match csi_param(params, 0, 0) {
                1 => {
                    self.lines.drain(..self.row.min(self.lines.len()));
                    self.row = 0;
                    let row = self.row;
                    self.row_mut(row).clear();
                }
                2 | 3 => self.clear_all(),
                // 0：光标到末尾清掉
                _ => {
                    let row = self.row;
                    let col = self.col;
                    let line = self.row_mut(row);
                    line.truncate(col.min(line.len()));
                    self.lines.truncate(row + 1);
                }
            },
            // 擦除行
            'K' => match csi_param(params, 0, 0) {
                1 => {
                    let row = self.row;
                    let col = self.col;
                    let line = self.row_mut(row);
                    line.drain(..col.min(line.len()));
                    self.col = 0;
                }
                2 => {
                    let row = self.row;
                    self.row_mut(row).clear();
                    self.col = 0;
                }
                // 0：光标到行尾清掉
                _ => {
                    let row = self.row;
                    let col = self.col;
                    let len = self.row_mut(row).len();
                    self.row_mut(row).truncate(col.min(len));
                }
            },
            // 上卷：丢弃顶部 n 行
            'S' => {
                let n = csi_param(params, 0, 1) as usize;
                let drop = n.min(self.lines.len().saturating_sub(1));
                self.lines.drain(..drop);
                self.row = self.row.saturating_sub(drop);
            }
            // 光标存取
            's' => self.saved = Some((self.row, self.col)),
            'u' => {
                if let Some((row, col)) = self.saved {
                    self.row = row;
                    self.col = col;
                    self.row_mut(row);
                }
            }
            // SGR 颜色与属性
            'm' => {
                let values: Vec<u16> = params.iter().flat_map(|g| g.iter().copied()).collect();
                let values = if values.is_empty() { vec![0] } else { values };
                let mut ix = 0;
                while ix < values.len() {
                    match values[ix] {
                        0 => self.style = SpanStyle::default(),
                        1 => self.style.bold = true,
                        22 => self.style.bold = false,
                        30..=37 => {
                            self.style.fg = TermColor::Indexed((values[ix] - 30) as u8);
                        }
                        39 => self.style.fg = TermColor::Default,
                        40..=47 => {
                            self.style.bg = TermColor::Indexed((values[ix] - 40) as u8);
                        }
                        49 => self.style.bg = TermColor::Default,
                        90..=97 => {
                            self.style.fg = TermColor::Indexed((values[ix] - 90 + 8) as u8);
                        }
                        100..=107 => {
                            self.style.bg = TermColor::Indexed((values[ix] - 100 + 8) as u8);
                        }
                        38 | 48 => {
                            let is_fg = values[ix] == 38;
                            let color = match values.get(ix + 1).copied() {
                                Some(5) => values
                                    .get(ix + 2)
                                    .copied()
                                    .map(|v| TermColor::Indexed(v.min(255) as u8)),
                                Some(2) => match (
                                    values.get(ix + 2).copied(),
                                    values.get(ix + 3).copied(),
                                    values.get(ix + 4).copied(),
                                ) {
                                    (Some(r), Some(g), Some(b)) => Some(TermColor::Rgb(
                                        r.min(255) as u8,
                                        g.min(255) as u8,
                                        b.min(255) as u8,
                                    )),
                                    _ => None,
                                },
                                _ => None,
                            };
                            if let Some(color) = color {
                                if is_fg {
                                    self.style.fg = color;
                                } else {
                                    self.style.bg = color;
                                }
                            }
                            ix += 4;
                        }
                        _ => {}
                    }
                    ix += 1;
                }
            }
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, byte: u8) {
        match byte {
            // RI：反向换行
            b'M' => {
                if self.row == 0 {
                    self.lines.insert(0, Vec::new());
                    if self.lines.len() > MAX_TERMINAL_LINES {
                        self.lines.pop();
                    }
                } else {
                    self.row -= 1;
                }
            }
            // DECSC / DECRC：光标存取
            b'7' => self.saved = Some((self.row, self.col)),
            b'8' => {
                if let Some((row, col)) = self.saved {
                    self.row = row;
                    self.col = col;
                    self.row_mut(row);
                }
            }
            // RIS：全复位
            b'c' => self.clear_all(),
            _ => {}
        }
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
    /// `vte` 解析器（输出实时出现，对齐 xterm 的流式展示）。
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
    screen: TermScreen,
    parser: Parser,
    focus_handle: FocusHandle,
}

impl TerminalView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            session: None,
            working_dir,
            screen: TermScreen::new(),
            parser: Parser::new(),
            focus_handle: cx.focus_handle(),
        };
        view.attach_session(cx);
        view
    }

    /// 打开 PTY 会话并起主线程输出泵（channel 收字节块 → `vte` 解析 → notify）。
    fn attach_session(&mut self, cx: &mut Context<Self>) {
        let shell = Self::resolve_shell(cx);
        match TerminalSession::new(
            TERMINAL_COLS as u16,
            TERMINAL_ROWS,
            &self.working_dir,
            &shell,
        ) {
            Ok((session, rx, displayed)) => {
                self.session = Some(session);
                self.screen.clear_all();
                let banner =
                    crate::i18n::menu_text(cx, "terminal.session").replace("{shell}", &displayed);
                for c in banner.chars() {
                    self.screen.put_char(c);
                }
                self.screen.newline();
                Self::spawn_pump(rx, cx);
            }
            Err(_) => {
                self.session = None;
            }
        }
        cx.notify();
    }

    /// 主线程输出泵：后台收字节块，回主线程喂解析器。
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
                            view.parser.advance(&mut view.screen, &bytes);
                            if view.screen.lines.len() > MAX_TERMINAL_LINES {
                                let overflow = view.screen.lines.len() - MAX_TERMINAL_LINES;
                                view.screen.lines.drain(..overflow);
                                view.screen.row = view.screen.row.saturating_sub(overflow);
                            }
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

    pub fn clear(&mut self, cx: &mut Context<Self>) {
        self.screen.clear_all();
        self.screen
            .put_str(&crate::i18n::menu_text(cx, "terminal.cleared").to_string());
        self.screen.newline();
        cx.notify();
    }

    /// 用现有工作目录重建 PTY 会话（失败则置空并通知）。
    pub fn respawn(&mut self, cx: &mut Context<Self>) {
        self.session = None;
        self.attach_session(cx);
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
                "up" => b"\x1b[A".to_vec(),
                "down" => b"\x1b[B".to_vec(),
                "right" => b"\x1b[C".to_vec(),
                "left" => b"\x1b[D".to_vec(),
                "home" => b"\x1b[H".to_vec(),
                "end" => b"\x1b[F".to_vec(),
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

impl TermScreen {
    /// 纯文本写入（banner/清空提示用当前默认样式）。
    fn put_str(&mut self, text: &str) {
        for c in text.chars() {
            if c == '\n' {
                self.newline();
            } else {
                self.put_char(c);
            }
        }
    }
}

impl Render for TerminalView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let focused = self.focus_handle.is_focused(window);
        let total = self.screen.lines.len();
        let start = total.saturating_sub(MAX_RENDER_LINES);
        let default_fg = ThemeColors::foreground();
        let default_bg = ThemeColors::background();

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
                    .children(
                        self.screen.lines[start..]
                            .iter()
                            .enumerate()
                            .map(|(ix, line)| {
                                render_term_line(
                                    start + ix,
                                    line,
                                    focused && start + ix == self.screen.row,
                                    self.screen.col,
                                    default_fg,
                                    default_bg,
                                )
                            })
                            .collect::<Vec<_>>(),
                    ),
            )
    }
}

/// 语义颜色解算（加粗配 0-7 自动取高亮 variant，标准终端行为）。
fn resolve_color(color: TermColor, bold: bool, default: Rgba) -> Rgba {
    match color {
        TermColor::Default => default,
        TermColor::Indexed(i) => {
            let i = if bold && i < 8 { i + 8 } else { i };
            rgba_of(palette_256(i))
        }
        TermColor::Rgb(r, g, b) => rgba_of((r, g, b)),
    }
}

/// 渲染一行：同样式字符合并为一段；聚焦时在光标处画反色块。
fn render_term_line(
    row: usize,
    line: &[StyledChar],
    cursor_here: bool,
    cursor_col: usize,
    default_fg: Rgba,
    default_bg: Rgba,
) -> gpui_kit::AnyElement {
    // 合并同样式段。
    let mut spans: Vec<(SpanStyle, String)> = Vec::new();
    for ch in line {
        if let Some((style, text)) = spans.last_mut() {
            if *style == ch.style {
                text.push(ch.c);
                continue;
            }
        }
        spans.push((ch.style, ch.c.to_string()));
    }
    let total: usize = spans.iter().map(|(_, text)| text.chars().count()).sum();
    // 光标超出文本末尾时在行尾补空格块。
    let trailing = cursor_here && cursor_col >= total;
    let mut row_el = h_flex()
        .id(row)
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
    for (style, text) in &spans {
        let fg = resolve_color(style.fg, style.bold, default_fg);
        let bg = resolve_color(style.bg, false, default_bg);
        let chunk = |text: String| {
            div()
                .text_color(fg)
                .when(style.bg != TermColor::Default, |el| el.bg(bg))
                .when(style.bold, |el| el.font_weight(FontWeight::BOLD))
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
                .bg(fg)
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
