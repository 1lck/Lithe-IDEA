//! 只读输出控制台：把字节流交给 `gpui_xterm` 终端组件渲染。
//!
//! Run/Maven 的受管进程跑在 PTY 上，输出是带 ANSI 的原始字节。这里用一个只读
//! 终端视图承接它们，得到彩色输出、`\r` 进度条覆盖与正确的宽字符/换行对齐，
//! 而不是逐行纯文本。控制台只渲染：输入写端是 `sink`，宿主通过 [`OutputConsole`]
//! 的写方法从 UI 线程喂字节。
//!
//! Note: 为什么受管进程必须跑 PTY、以及只读控制台的边界见
//! `.agents/notes/implemented/feature/2026-09-26-linux-run-console-pty-terminal.md`。

use std::io::{self, Read};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

use gpui_kit::{px, App, ClipboardItem, Edges, Entity};
use gpui_xterm::{TerminalConfig, TerminalView};
use portable_pty::PtySize;

use crate::settings;

/// 控制台行列数兜底值：首帧测量前与异常情况下使用。
const FALLBACK_COLS: u16 = 120;
const FALLBACK_ROWS: u16 = 30;
/// PTY 行列数下限，避免退化到 0。
const MIN_COLS: u16 = 20;
const MIN_ROWS: u16 = 5;
/// 控制台内容内边距。
const PADDING: f32 = 4.0;

/// 错误行配色（亮红）。
const ANSI_ERROR: &str = "\x1b[91m";
/// 表头/命令行的强调（粗体）。
const ANSI_BOLD: &str = "\x1b[1m";
/// 次要提示（256 色灰）。
const ANSI_MUTED: &str = "\x1b[38;5;245m";
const ANSI_RESET: &str = "\x1b[0m";

/// 把收到的字节块按顺序交给 `Read` 的适配器；所有发送端 drop 后返回 EOF。
struct ChannelReader {
    rx: mpsc::Receiver<Vec<u8>>,
    buf: Vec<u8>,
    pos: usize,
}

impl Read for ChannelReader {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        while self.pos >= self.buf.len() {
            match self.rx.recv() {
                Ok(next) => {
                    self.buf = next;
                    self.pos = 0;
                }
                Err(_) => return Ok(0),
            }
        }
        let available = &self.buf[self.pos..];
        let count = available.len().min(out.len());
        out[..count].copy_from_slice(&available[..count]);
        self.pos += count;
        Ok(count)
    }
}

/// 只读输出控制台：终端视图 + 写端 + 最近一次实测尺寸。
pub struct OutputConsole {
    /// 终端视图实体，直接作为元素渲染。
    pub view: Entity<TerminalView>,
    tx: mpsc::Sender<Vec<u8>>,
    /// 终端视图上报的行列数，作为受管进程 PTY 的初始尺寸。
    size: Arc<Mutex<(u16, u16)>>,
    /// 是否写入过内容；宿主据此决定“清空”等动作是否可用。
    has_output: bool,
}

impl OutputConsole {
    /// 创建控制台。视图的生命周期与写端一致：写端常驻，读取线程不会提前 EOF。
    pub fn new(cx: &mut impl gpui_kit::AppContext) -> Self {
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let size = Arc::new(Mutex::new((FALLBACK_COLS, FALLBACK_ROWS)));
        let size_slot = size.clone();
        let view = cx.new(move |cx| {
            let config = console_config(cx);
            let reader = ChannelReader {
                rx,
                buf: Vec::new(),
                pos: 0,
            };
            TerminalView::new(io::sink(), reader, config, cx)
                .with_context_menu_labels(crate::workbench::terminal::context_menu_labels(cx))
                .with_resize_callback(move |cols, rows| {
                    if let Ok(mut slot) = size_slot.lock() {
                        *slot = (
                            (cols as u16).clamp(MIN_COLS, u16::MAX),
                            (rows as u16).clamp(MIN_ROWS, u16::MAX),
                        );
                    }
                })
        });
        Self {
            view,
            tx,
            size,
            has_output: false,
        }
    }

    /// 写入原始字节（受管进程的 PTY 输出）。
    pub fn write_bytes(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.has_output = true;
        let _ = self.tx.send(bytes.to_vec());
    }

    /// 写入一行宿主自己的文本（命令回显、状态、错误）。
    pub fn write_text(&mut self, text: &str, ansi: Option<&str>) {
        let line = match ansi {
            Some(prefix) => format!("{prefix}{text}{ANSI_RESET}\r\n"),
            None => format!("{text}\r\n"),
        };
        self.write_bytes(line.as_bytes());
    }

    /// 命令回显/表头（粗体）。
    pub fn write_heading(&mut self, text: &str) {
        self.write_text(text, Some(ANSI_BOLD));
    }

    /// 次要提示（灰）。
    pub fn write_muted(&mut self, text: &str) {
        self.write_text(text, Some(ANSI_MUTED));
    }

    /// 错误（红）。
    pub fn write_error(&mut self, text: &str) {
        self.write_text(text, Some(ANSI_ERROR));
    }

    /// 清屏并复位光标。
    pub fn clear(&mut self) {
        let _ = self.tx.send(b"\x1b[2J\x1b[H".to_vec());
        self.has_output = false;
    }

    /// 是否还没有输出（宿主门控用，与 `Vec::is_empty` 语义一致）。
    pub fn is_empty(&self) -> bool {
        !self.has_output
    }

    /// 受管进程 PTY 的初始尺寸（钳制到下限）。
    pub fn size(&self) -> PtySize {
        let (cols, rows) = self
            .size
            .lock()
            .map(|slot| *slot)
            .unwrap_or((FALLBACK_COLS, FALLBACK_ROWS));
        PtySize {
            cols: cols.max(MIN_COLS),
            rows: rows.max(MIN_ROWS),
            pixel_width: 0,
            pixel_height: 0,
        }
    }

    /// 把视口滚到底部（“跟随末尾”）。
    pub fn scroll_to_bottom(&self, cx: &mut impl gpui_kit::AppContext) {
        self.view.update(cx, |view, cx| {
            view.state().scroll_to_bottom();
            cx.notify();
        });
    }

    /// 主题变化时把新调色板/字体推给控制台。
    ///
    /// 走组件已有的 `TerminalView::update_config`；不推的话切到深色主题后控制台
    /// 仍保持创建时的浅色配色。
    pub fn apply_config(&self, cx: &mut App) {
        let config = console_config(cx);
        self.view.update(cx, |view, cx| view.update_config(config, cx));
    }

    /// 把控制台当前选区写入 GPUI 的平台剪贴板。
    ///
    /// 与集成终端同理：组件的复制用临时 `arboard` 句柄，X11 下可能丢数据，宿主
    /// 侧再用 GPUI 剪贴板写一次兜底。返回是否复制了非空选区。
    pub fn copy_selection(&self, cx: &mut App) -> bool {
        let text = self
            .view
            .read(cx)
            .state()
            .with_term(|term| term.selection_to_string());
        match text.filter(|text| !text.is_empty()) {
            Some(text) => {
                cx.write_to_clipboard(ClipboardItem::new_string(text));
                true
            }
            None => false,
        }
    }
}

/// 控制台终端配置：等宽字体跟随设置，配色取工作台主题 token。
fn console_config(cx: &App) -> TerminalConfig {
    let s = settings::get(cx);
    TerminalConfig {
        cols: FALLBACK_COLS as usize,
        rows: FALLBACK_ROWS as usize,
        font_family: crate::fonts::mono_family(cx).to_string(),
        font_size: px(s.terminal_font_size),
        scrollback: s.terminal_scrollback.max(1),
        line_height_multiplier: 1.0,
        padding: Edges::all(px(PADDING)),
        colors: crate::workbench::terminal::terminal_color_palette(),
    }
}
