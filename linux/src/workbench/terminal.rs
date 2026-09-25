//! Linux 内嵌终端：`portable-pty` 拥有 PTY 与子进程生命周期，
//! `alacritty_terminal` 拥有全部终端语义（ANSI 解析、网格、回滚、选择、搜索、
//! resize/reflow），本文件只做四件事：
//!
//! 1. **会话层**（[`TerminalSession`]）：打开/关闭 PTY，回收子进程与 reader
//!    线程，上报退出码与信号；终止路径复用 `run::process` 的进程组契约。
//! 2. **事件接线**：键盘与鼠标映射成 PTY 字节，或 IDE 行为（搜索、视口滚动、
//!    复制粘贴、回到底部）。
//! 3. **渲染投影**：把上游 `display_iter` 的可见网格按实测单元格宽度排版成
//!    GPUI 元素，语义全部来自上游 `Flags` / `TermMode` / `CursorShape`。
//! 4. **宿主 API**：新建/关闭会话、切换工作目录、清屏、程序化发送命令。
//!
//! 必须遵守的边界：终端语义只能来自 `alacritty_terminal`。不要在这里手写
//! ANSI 解析、换行、光标移动或滚动缓冲；滚动只调 `Term::scroll_display`，复制
//! 只调 `Term::selection_to_string`，搜索只用 `term::search::RegexSearch` +
//! `Term::search_next`，缩放只调 `Term::resize`（reflow 由上游完成）。
//!
//! 适配声明：当前是单会话 UI——没有多标签、横向分屏、超链接点击与 Sixel/Kitty
//! 图形协议。会话层不依赖 GPUI，后续加标签只需在 [`TerminalView`] 上并列多个
//! [`TerminalSession`]，不需要改引擎接线。
//!
//! Note: 引擎复用边界与禁止手写终端语义的原因见
//! `.agents/notes/implemented/architecture/2026-09-25-linux-gpui-terminal-engine-reuse.md`。

use std::cell::Cell as StdCell;
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Direction, Line, Point as GridPoint, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::search::{Match, RegexSearch};
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color as AlacColor, CursorShape, NamedColor, Processor, Rgb};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, App, Bounds, ClipboardItem, Context, FocusHandle, FontWeight, InteractiveElement as _,
    IntoElement, KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent,
    ParentElement as _, Pixels, Point, Render, Rgba, ScrollDelta, ScrollWheelEvent, Size,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window,
};
use portable_pty::{native_pty_system, Child, ChildKiller, CommandBuilder, MasterPty, PtySize};

use crate::settings;
use crate::theme::{self, ThemeColors};
use crate::workbench::run::process::terminate_process_group;
use crate::workbench::search_input::SearchInput;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 引导网格尺寸：只用于 `Term::new` 与“首次开会话”这一刻。首个 prepaint
/// 拿到实测容器尺寸后立刻 `Term::resize` + PTY resize，不会停留在该值。
const BOOTSTRAP_COLS: usize = 80;
const BOOTSTRAP_ROWS: usize = 24;

/// 网格最小尺寸，避免退化到 0 列触发上游断言（上游要求至少 2 列放全角字符）。
const MIN_COLS: usize = 2;
const MIN_ROWS: usize = 1;

/// PTY 行列数上限：超过这个尺寸的“窗口”多半是布局异常，钳住避免无意义 resize。
const MAX_COLS: usize = 1000;
const MAX_ROWS: usize = 1000;

/// 行高相对字号的倍率（等宽终端常用 1.4）。
const LINE_HEIGHT_RATIO: f32 = 1.4;

/// 网格内容内边距（左侧与上侧偏移，鼠标命中换算需扣除）。
const GRID_PADDING: f32 = 4.0;

/// 关闭会话时先温和终止的等待时长；超时升级为强杀。与 `run::process` 的停止
/// 契约一致：宁可多等，也不给用户留下孤儿 shell。
const SESSION_STOP_GRACE: Duration = Duration::from_secs(2);

/// 强杀后的兜底等待时长；仍不退出即放弃等待（子进程已收到 KILL，由内核回收）。
const SESSION_KILL_GRACE: Duration = Duration::from_millis(500);

/// reader 线程单次读取的字节数。
const READER_CHUNK: usize = 16 * 1024;

/// 光标闪烁间隔（设置 `terminal_cursor_blink` 打开时使用）。
const CURSOR_BLINK_INTERVAL: Duration = Duration::from_millis(530);

/// 搜索命中的计数上限：回滚缓冲可能有十万行，正则全量扫描必须有界。
/// 超出后计数带 `+`，导航仍然正确（只截断总数展示）。
const SEARCH_MATCH_CAP: usize = 512;

/// 亮色变体向前景色混合的比例（ANSI 8-15 = 基础色 + 前景色）。
const BRIGHT_MIX: f32 = 0.55;

/// 暗色变体向背景色混合的比例（`DimXxx` = 基础色 + 背景色）。
const DIM_MIX: f32 = 0.45;

/// `Flags::DIM` 的前景向背景混合比例。
const CELL_DIM_MIX: f32 = 0.35;

/// 终端 PTY 的 `TERM`：声明 256 色，与 `COLORTERM=truecolor` 配套。
const PTY_TERM: &str = "xterm-256color";
const PTY_COLORTERM: &str = "truecolor";

/// 宿主终端遗留的环境变量：会让 PTY 里的程序误判“谁是宿主终端”，或读到
/// 上一份终端的缓存几何。启动会话前一律清掉。
///
/// 保留 `TMUX`/`STY` 是有意的：嵌在 tmux/screen 里时透传它，嵌套会话才能
/// 正确识别外层。
const HOST_TERMINAL_VARIABLES: &[&str] = &[
    "LINES",
    "COLUMNS",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "TERMINAL_EMULATOR",
    "TERMINAL_EMULATOR_VERSION",
    "WT_SESSION",
    "KITTY_WINDOW_ID",
    "KITTY_LISTEN_ON",
    "ALACRITTY_WINDOW_ID",
    "ALACRITTY_SOCKET",
    "ITERM_SESSION_ID",
    "VTE_VERSION",
    "GNOME_TERMINAL_SCREEN",
    "GNOME_TERMINAL_SERVICE",
    "KONSOLE_VERSION",
    "KONSOLE_DBUS_SESSION",
    "TERMINAL_SCREEN",
];

// ---------------------------------------------------------------------------
// 网格与几何（纯逻辑）
// ---------------------------------------------------------------------------

/// 网格尺寸（`Term::new` 与 `resize` 共用）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TermDims {
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

/// 单元格像素尺寸。渲染排版、鼠标命中换算与 PTY 行列数三处必须共用它，
/// 否则宽字符与样式分段会出现半格偏移。
#[derive(Debug, Clone, Copy, PartialEq)]
struct CellMetrics {
    width: f32,
    height: f32,
}

impl CellMetrics {
    /// 按当前字号实测等宽字符宽度；行高按倍率换算。
    fn measure(window: &Window, font_size: Pixels) -> Self {
        let font = gpui_kit::Font {
            family: "monospace".into(),
            ..Default::default()
        };
        let font_id = window.text_system().resolve_font(&font);
        let width = f32::from(window.text_system().em_layout_width(font_id, font_size)).max(1.0);
        Self {
            width,
            height: f32::from(font_size) * LINE_HEIGHT_RATIO,
        }
    }

    /// 容器内容区尺寸 → 网格行列数。容器还没布局完成（宽或高 ≤ 0）时返回
    /// `None`，此时不得 resize 上游网格。
    fn grid_dims(&self, size: Size<Pixels>) -> Option<TermDims> {
        let width = f32::from(size.width) - GRID_PADDING * 2.0;
        let height = f32::from(size.height) - GRID_PADDING * 2.0;
        if width <= 0.0 || height <= 0.0 {
            return None;
        }
        Some(TermDims {
            cols: ((width / self.width).floor() as usize).clamp(MIN_COLS, MAX_COLS),
            rows: ((height / self.height).floor() as usize).clamp(MIN_ROWS, MAX_ROWS),
        })
    }
}

/// 容器内局部坐标（已扣除容器原点）→ 网格点。
///
/// 先扣除网格内边距，再按单元格尺寸取整；越界返回 `None`。视口行需叠加
/// 回滚偏移才是网格行（上游 `viewport_to_point` 语义），这样上滚后鼠标
/// 选择仍命中用户看到的同一行。
fn viewport_to_grid_point(
    local_x: f32,
    local_y: f32,
    cell: CellMetrics,
    size: TermDims,
    display_offset: usize,
) -> Option<GridPoint> {
    let local_x = local_x - GRID_PADDING;
    let local_y = local_y - GRID_PADDING;
    if local_x < 0.0 || local_y < 0.0 {
        return None;
    }

    let col = (local_x / cell.width).floor() as usize;
    let viewport_line = (local_y / cell.height).floor() as usize;
    if col >= size.cols || viewport_line >= size.rows {
        return None;
    }

    let line = Line(viewport_line as i32 - display_offset as i32);
    Some(GridPoint::new(line, Column(col)))
}

// ---------------------------------------------------------------------------
// 生命周期状态机（纯逻辑）
// ---------------------------------------------------------------------------

/// 会话结束方式：正常退出码，或被信号杀死。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalExit {
    /// 进程以退出码结束。
    Code(i32),
    /// 进程被信号终止（信号名来自 `portable-pty` 的 `ExitStatus`）。
    Signal(String),
    /// 会话已请求关闭，但没拿到退出状态。
    Unknown,
}

impl TerminalExit {
    /// 展示用明细：供 i18n 模板的 `{detail}` 替换。
    pub fn detail(&self) -> String {
        match self {
            Self::Code(code) => code.to_string(),
            Self::Signal(signal) => signal.clone(),
            Self::Unknown => String::new(),
        }
    }
}

/// 终端会话生命周期。会话层与视图层共享同一套状态语义，视图只读它来决定
/// 空态、状态条与是否允许发送输入。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionState {
    /// 还没有 PTY 会话（面板刚建，或用户显式关闭了会话）。
    Closed,
    /// 子进程在跑。
    Running,
    /// 已发出停止信号，等待子进程退出或被强杀。
    Stopping,
    /// 子进程已回收。
    Exited(TerminalExit),
}

impl SessionState {
    /// 是否还持有可用的 PTY（能写字节、能 resize）。
    pub fn is_attached(&self) -> bool {
        matches!(self, Self::Running | Self::Stopping)
    }
}

/// 驱动 [`SessionState`] 迁移的事件。
#[derive(Debug, Clone, PartialEq, Eq)]
enum SessionEventKind {
    Spawned,
    StopRequested,
    Reaped(TerminalExit),
}

impl SessionState {
    /// 纯状态迁移。非法迁移保持原状态，调用方可以无条件应用结果。
    fn transition(self, event: SessionEventKind) -> Self {
        match (event, self) {
            (SessionEventKind::Spawned, Self::Closed | Self::Exited(_)) => Self::Running,
            (SessionEventKind::StopRequested, Self::Running | Self::Stopping) => Self::Stopping,
            (SessionEventKind::Reaped(exit), Self::Running | Self::Stopping | Self::Closed) => {
                Self::Exited(exit)
            }
            (_, state) => state,
        }
    }
}

/// 生命周期驱动器：把 [`SessionEventKind`] 顺序应用到 [`SessionState`] 上。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct SessionLifecycle {
    state: Option<SessionState>,
}

impl SessionLifecycle {
    fn new() -> Self {
        Self { state: None }
    }

    /// 当前状态；从未创建过会话时为 `Closed`。
    fn state(&self) -> SessionState {
        self.state.clone().unwrap_or(SessionState::Closed)
    }

    fn apply(&mut self, event: SessionEventKind) -> SessionState {
        let next = self.state().transition(event);
        self.state = Some(next.clone());
        next
    }
}

// ---------------------------------------------------------------------------
// PTY 环境与 shell 解析（纯逻辑）
// ---------------------------------------------------------------------------

/// 生成 PTY 子进程的环境：清掉宿主终端遗留变量，并写入终端能力声明。
///
/// 纯函数，便于断言“哪些变量被清理、哪些被覆盖”。
fn pty_environment(base: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let mut env: BTreeMap<String, String> = base
        .iter()
        .filter(|(key, _)| !HOST_TERMINAL_VARIABLES.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    env.insert("TERM".to_string(), PTY_TERM.to_string());
    env.insert("COLORTERM".to_string(), PTY_COLORTERM.to_string());
    env
}

/// 解析生效 shell：设置 `terminalDefaultShellId` 非空即用（名称经 `PATH`
/// 解析为路径），为空回退平台默认 shell。
fn resolve_shell(configured: &str) -> String {
    let id = configured.trim();
    if id.is_empty() {
        return default_shell();
    }
    // 已含路径分隔符（`/` 或 `\`）时视为绝对/相对路径，直接使用。
    if id.contains('/') || id.contains('\\') {
        return id.to_string();
    }
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            for candidate in shell_candidates(&dir, id) {
                if candidate.is_file() {
                    return candidate.to_string_lossy().to_string();
                }
            }
        }
    }
    // 某些发行版的 shell 不在 PATH 中，退回固定系统目录。
    if cfg!(unix) {
        let fallback = std::path::PathBuf::from("/bin").join(id);
        if fallback.is_file() {
            return fallback.to_string_lossy().to_string();
        }
    }
    id.to_string()
}

/// 平台默认 shell：Unix 用登录 shell（`$SHELL`），Windows 用 `COMSPEC`。
///
/// 两个变量都缺失时给出该平台最可能存在的回退名，避免空 program 导致 PTY
/// 启动失败。
fn default_shell() -> String {
    if cfg!(unix) {
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
    } else {
        std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_string())
    }
}

/// 列出在 `dir` 下应该尝试的 shell 可执行文件名。
///
/// Windows 上按 `PATHEXT` 补全（`pwsh` -> `pwsh.exe`）；名字已带扩展名或非
/// Windows 平台时只尝试原名。
fn shell_candidates(dir: &std::path::Path, name: &str) -> Vec<std::path::PathBuf> {
    let mut candidates = vec![dir.join(name)];
    if cfg!(windows) && std::path::Path::new(name).extension().is_none() {
        let pathext =
            std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
        for extension in pathext.split(';').filter(|value| !value.is_empty()) {
            candidates.push(dir.join(format!("{name}{extension}")));
        }
    }
    candidates
}

// ---------------------------------------------------------------------------
// 键盘映射（纯逻辑）
// ---------------------------------------------------------------------------

/// 终端按键修饰键。用自有结构而不是 GPUI 的 `Modifiers`，让映射函数可以脱离
/// 窗口单测。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct KeyModifiers {
    control: bool,
    alt: bool,
    shift: bool,
    platform: bool,
}

impl From<&gpui_kit::Modifiers> for KeyModifiers {
    fn from(value: &gpui_kit::Modifiers) -> Self {
        Self {
            control: value.control,
            alt: value.alt,
            shift: value.shift,
            platform: value.platform,
        }
    }
}

/// 按键的最终归宿。
#[derive(Debug, Clone, PartialEq, Eq)]
enum KeyAction {
    /// 写入 PTY 的字节。
    Send(Vec<u8>),
    /// 复制当前选区。
    Copy,
    /// 从剪贴板粘贴。
    Paste,
    /// 打开终端内搜索。
    OpenSearch,
    /// 视口相对滚动（正数向上，即更早的输出）。
    Scroll(isize),
    /// 回到输出末尾。
    ScrollToBottom,
    /// 不消费，交给工作台全局快捷键。
    Passthrough,
}

/// 键名 → 终端字节序列。方向键/Home/End 同时给出普通模式与应用光标模式两套，
/// 模式由上游 `TermMode::APP_CURSOR` 决定。
fn key_bytes(key: &str, term_mode: TermMode) -> Option<Vec<u8>> {
    // 显式标注成切片：带 `~` 的序列长度与方向键不同，数组字面量无法统一。
    let (normal, application): (&[u8], &[u8]) = match key {
        "up" => (b"\x1b[A", b"\x1bOA"),
        "down" => (b"\x1b[B", b"\x1bOB"),
        "right" => (b"\x1b[C", b"\x1bOC"),
        "left" => (b"\x1b[D", b"\x1bOD"),
        "home" => (b"\x1b[H", b"\x1bOH"),
        "end" => (b"\x1b[F", b"\x1bOF"),
        "insert" => (b"\x1b[2~", b"\x1b[2~"),
        "delete" => (b"\x1b[3~", b"\x1b[3~"),
        "pageup" => (b"\x1b[5~", b"\x1b[5~"),
        "pagedown" => (b"\x1b[6~", b"\x1b[6~"),
        "f1" => (b"\x1bOP", b"\x1bOP"),
        "f2" => (b"\x1bOQ", b"\x1bOQ"),
        "f3" => (b"\x1bOR", b"\x1bOR"),
        "f4" => (b"\x1bOS", b"\x1bOS"),
        "f5" => (b"\x1b[15~", b"\x1b[15~"),
        "f6" => (b"\x1b[17~", b"\x1b[17~"),
        "f7" => (b"\x1b[18~", b"\x1b[18~"),
        "f8" => (b"\x1b[19~", b"\x1b[19~"),
        "f9" => (b"\x1b[20~", b"\x1b[20~"),
        "f10" => (b"\x1b[21~", b"\x1b[21~"),
        "f11" => (b"\x1b[23~", b"\x1b[23~"),
        "f12" => (b"\x1b[24~", b"\x1b[24~"),
        _ => return None,
    };
    Some(
        if term_mode.contains(TermMode::APP_CURSOR) {
            application
        } else {
            normal
        }
        .to_vec(),
    )
}

/// Ctrl + 字母/符号 → 控制字符（Ctrl+C 中断、Ctrl+D EOF 等）。
fn control_byte(key: &str) -> Option<Vec<u8>> {
    let lower = key.to_lowercase();
    let mut chars = lower.chars();
    match (chars.next(), chars.next()) {
        (Some(c @ 'a'..='z'), None) => Some(vec![(c as u8) - b'a' + 1]),
        (Some(' '), None) => Some(vec![0]),
        (Some('['), None) => Some(vec![0x1b]),
        (Some('\\'), None) => Some(vec![0x1c]),
        (Some(']'), None) => Some(vec![0x1d]),
        (Some('^'), None) => Some(vec![0x1e]),
        (Some('_'), None) => Some(vec![0x1f]),
        _ => None,
    }
}

/// 单个按键的映射结果。`visible_rows` 用于把翻页动作换算成行数。
fn map_key(
    key: &str,
    key_char: Option<&str>,
    mods: KeyModifiers,
    term_mode: TermMode,
    visible_rows: usize,
) -> KeyAction {
    // ---- IDE 语义：复制/粘贴/搜索/视口滚动（放在控制字符之前，避免被吞）----
    // 对齐 Windows 终端的 `getTerminalKeyAction`：非 macOS 平台
    // Ctrl+Shift+C/V 为复制粘贴，Ctrl+V 也直接粘贴（否则 shell 只会显示 ^V）。
    if mods.control && !mods.alt && !mods.platform {
        let lower = key.to_lowercase();
        if mods.shift {
            match lower.as_str() {
                "c" => return KeyAction::Copy,
                "v" => return KeyAction::Paste,
                "f" => return KeyAction::OpenSearch,
                _ => {}
            }
        } else {
            match lower.as_str() {
                "v" => return KeyAction::Paste,
                "f" => return KeyAction::OpenSearch,
                "end" => return KeyAction::ScrollToBottom,
                _ => {}
            }
        }
    }
    // Shift+翻页：滚视口，不把按键交给 PTY（xterm/IDEA 的共同行为）。
    if mods.shift && !mods.control && !mods.alt && !mods.platform {
        let page = visible_rows.max(1) as isize;
        match key {
            "pageup" => return KeyAction::Scroll(page),
            "pagedown" => return KeyAction::Scroll(-page),
            _ => {}
        }
    }

    // ---- 直输与控制字符 ----
    if mods.control && !mods.alt && !mods.platform {
        return match control_byte(key) {
            Some(bytes) => KeyAction::Send(bytes),
            // Ctrl+其它组合键归工作台（如 Ctrl+W 关标签）。
            None => KeyAction::Passthrough,
        };
    }
    if mods.alt && !mods.control && !mods.platform {
        // Alt+字符 → ESC 前缀（readline Meta 键）；Alt+方向键 → 词移动。
        return match key {
            "left" => KeyAction::Send(b"\x1b[b".to_vec()),
            "right" => KeyAction::Send(b"\x1b[f".to_vec()),
            "backspace" => KeyAction::Send(b"\x1b\x7f".to_vec()),
            _ => match key_char {
                Some(text) if text.chars().count() == 1 => {
                    let mut out = vec![0x1b];
                    out.extend_from_slice(text.as_bytes());
                    KeyAction::Send(out)
                }
                _ => KeyAction::Passthrough,
            },
        };
    }
    // 平台键（Super/Win）与 AltGr（Ctrl+Alt）都不是终端输入，放行给上层。
    if mods.platform || (mods.control && mods.alt) {
        return KeyAction::Passthrough;
    }

    match key {
        "enter" => KeyAction::Send(b"\r".to_vec()),
        "backspace" => KeyAction::Send(vec![0x7f]),
        "tab" => KeyAction::Send(b"\t".to_vec()),
        "escape" => KeyAction::Send(vec![0x1b]),
        _ => {
            if let Some(bytes) = key_bytes(key, term_mode) {
                return KeyAction::Send(bytes);
            }
            match key_char {
                // 可打印字符（含中文）原样直输。
                Some(text) if !text.is_empty() => KeyAction::Send(text.as_bytes().to_vec()),
                _ => KeyAction::Passthrough,
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 鼠标上报（纯逻辑）
// ---------------------------------------------------------------------------

/// 需要上报给终端应用的鼠标动作。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MouseReport {
    /// 按下；`button` 为 0 左 / 1 中 / 2 右。
    Press(u8),
    /// 抬起。
    Release(u8),
    /// 按住拖动。
    Drag(u8),
}

/// 上游 `TermMode` 是否要求把该动作上报给应用（否则走本地文本选择）。
fn mouse_report_enabled(action: MouseReport, mode: TermMode) -> bool {
    match action {
        MouseReport::Drag(_) => mode.contains(TermMode::MOUSE_MOTION),
        _ => mode.contains(TermMode::MOUSE_REPORT_CLICK),
    }
}

/// 滚轮手势取值：Shift+滚轮在 Linux 上是横向手势，终端按行处理时也把它
/// 当成纵向滚动。
fn wheel_axis(shift: bool, x: f64, y: f64) -> f64 {
    if shift && x != 0.0 {
        x
    } else {
        y
    }
}

/// 编码鼠标上报字节。
///
/// 优先 SGR 1006（`CSI < b ; col ; row M/m`），回退 X10（`CSI M b+32 …`）。
/// 行列按终端协议从 1 开始，并叠加回滚偏移（终端报告的是视口坐标）。
fn encode_mouse_report(
    action: MouseReport,
    point: GridPoint,
    display_offset: usize,
    sgr: bool,
) -> Vec<u8> {
    let (button, final_byte) = match action {
        MouseReport::Press(button) => (button, b'M'),
        MouseReport::Release(button) => (button + 3, b'm'),
        MouseReport::Drag(button) => (button + 32, b'M'),
    };
    let column = point.column.0 + 1;
    let row = (point.line.0 + display_offset as i32 + 1).max(1) as usize;
    if sgr {
        format!("\x1b[<{button};{column};{row}{}", final_byte as char).into_bytes()
    } else {
        let mut out = vec![0x1b, b'[', b'M', 32 + button];
        out.push((32 + column.min(223)) as u8);
        out.push((32 + row.min(223)) as u8);
        out
    }
}

// ---------------------------------------------------------------------------
// 搜索（纯逻辑 + 上游正则）
// ---------------------------------------------------------------------------

/// 命中序号（1 起）按方向推进并环绕；无命中返回 0。
fn next_match_index(current: usize, total: usize, forward: bool) -> usize {
    if total == 0 {
        return 0;
    }
    if current == 0 {
        return 1;
    }
    let current = current.min(total);
    if forward {
        current % total + 1
    } else {
        (current + total - 2) % total + 1
    }
}

/// 搜索计数展示文案：无命中为 `0/0`；超出上限带 `+`。
fn match_label(current: usize, total: usize, truncated: bool) -> String {
    if total == 0 {
        return "0/0".to_string();
    }
    let suffix = if truncated { "+" } else { "" };
    format!("{}/{total}{suffix}", current.min(total))
}

/// 一次命中的下一搜索起点：命中结束后一列；行尾则换到下一行首列。
fn next_search_origin<T>(term: &Term<T>, found: &Match) -> Option<GridPoint> {
    let end = *found.end();
    if end.column < term.last_column() {
        return Some(GridPoint::new(end.line, Column(end.column.0 + 1)));
    }
    if end.line.0 + 1 < term.total_lines() as i32 {
        return Some(GridPoint::new(Line(end.line.0 + 1), Column(0)));
    }
    None
}

/// 从网格最旧一行开始收集全部命中，直到没有更多或达到 [`SEARCH_MATCH_CAP`]。
///
/// 顺序收集而不是“每次从光标重新搜”，这样“下一个/上一个”的计数、环绕和
/// 高亮落点都与 xterm 的 SearchAddon 一致。
///
/// 上游 `search_next` 在“起点之后没有命中”时会回退返回第一个命中，因此必须
/// 自己判断是否已经环绕：命中起点不再前进即视为收集结束。
fn collect_matches<T>(term: &Term<T>, regex: &mut RegexSearch, cap: usize) -> (Vec<Match>, bool) {
    let mut matches: Vec<Match> = Vec::new();
    let mut origin = GridPoint::new(term.topmost_line(), Column(0));
    while matches.len() < cap {
        let Some(found) = term.search_next(regex, origin, Direction::Right, Side::Left, None)
        else {
            break;
        };
        if matches
            .last()
            .is_some_and(|last| *found.start() <= *last.start())
        {
            // 已经环绕回前面的命中，收集结束。
            break;
        }
        let next = next_search_origin(term, &found);
        matches.push(found);
        match next {
            Some(next) => origin = next,
            // 命中在缓冲末尾，没有下一处起点。
            None => break,
        }
    }
    let truncated = matches.len() >= cap;
    (matches, truncated)
}

/// 终端内搜索状态：查询串、上游正则缓存、有界的命中列表与当前序号。
struct SearchState {
    query: String,
    regex: Option<RegexSearch>,
    matches: Vec<Match>,
    /// 当前命中序号（1 起，0 表示无命中）。
    current: usize,
    /// 命中数是否被 [`SEARCH_MATCH_CAP`] 截断。
    truncated: bool,
}

impl SearchState {
    fn new() -> Self {
        Self {
            query: String::new(),
            regex: None,
            matches: Vec::new(),
            current: 0,
            truncated: false,
        }
    }

    fn is_empty(&self) -> bool {
        self.query.is_empty()
    }

    fn total(&self) -> usize {
        self.matches.len()
    }

    /// 当前命中的高亮范围；无命中返回 `None`。
    fn current_match(&self) -> Option<Match> {
        if self.current == 0 {
            return None;
        }
        self.matches.get(self.current - 1).cloned()
    }

    /// 计数文案，供搜索栏展示。
    fn label(&self) -> String {
        if self.is_empty() {
            return String::new();
        }
        match_label(self.current, self.total(), self.truncated)
    }

    /// 换查询串：重建上游正则并重新收集命中，序号复位到首个命中。
    fn set_query(&mut self, term: &Term<VoidListener>, query: String) {
        self.query = query;
        self.matches.clear();
        self.current = 0;
        self.truncated = false;
        if self.query.is_empty() {
            self.regex = None;
            return;
        }
        match RegexSearch::new(&self.query) {
            Ok(regex) => self.regex = Some(regex),
            Err(error) => {
                // 非法正则：当作无命中，并且不保留上一次的查询串。
                tracing::warn!("terminal search pattern rejected: {error}");
                self.query.clear();
                self.regex = None;
                return;
            }
        }
        self.jump_to_first(term);
    }

    /// 跳到首个命中（无命中时保持 `current = 0`）。
    fn jump_to_first(&mut self, term: &Term<VoidListener>) {
        let Some(regex) = self.regex.as_mut() else {
            return;
        };
        let (matches, truncated) = collect_matches(term, regex, SEARCH_MATCH_CAP);
        self.matches = matches;
        self.truncated = truncated;
        self.current = usize::from(!self.matches.is_empty());
    }

    /// 上一个/下一个命中（环绕）。返回应高亮的范围。
    fn step(&mut self, forward: bool) -> Option<Match> {
        if self.matches.is_empty() {
            self.current = 0;
            return None;
        }
        self.current = next_match_index(self.current, self.matches.len(), forward);
        self.current_match()
    }

    fn clear(&mut self) {
        self.query.clear();
        self.regex = None;
        self.matches.clear();
        self.current = 0;
        self.truncated = false;
    }
}

// ---------------------------------------------------------------------------
// 渲染调色板（纯逻辑）
// ---------------------------------------------------------------------------

fn rgba_of(rgb: (u8, u8, u8)) -> Rgba {
    Rgba {
        r: rgb.0 as f32 / 255.0,
        g: rgb.1 as f32 / 255.0,
        b: rgb.2 as f32 / 255.0,
        a: 1.0,
    }
}

/// 终端渲染调色板：8 个基础色来自主题 `terminal_*` token，亮/暗变体与
/// 256 色由基础色派生。仓库里不再保留第二份硬编码 ANSI 调色板。
struct TermPalette {
    /// black/red/green/yellow/blue/magenta/cyan/white。
    base: [Rgba; 8],
    foreground: Rgba,
    background: Rgba,
    cursor: Rgba,
    selection: Rgba,
    dimmed_foreground: Rgba,
}

impl TermPalette {
    fn from_theme() -> Self {
        let palette = theme::palette();
        Self {
            base: [
                palette.terminal_black,
                palette.terminal_red,
                palette.terminal_green,
                palette.terminal_yellow,
                palette.terminal_blue,
                palette.terminal_magenta,
                palette.terminal_cyan,
                palette.terminal_white,
            ],
            foreground: palette.foreground,
            background: palette.background,
            cursor: palette.foreground,
            selection: palette.selection,
            dimmed_foreground: palette.muted_foreground,
        }
    }

    /// 亮色变体（ANSI 8-15）：基础色向前景色混合。
    fn bright(&self, index: usize) -> Rgba {
        theme::mix(self.base[index], self.foreground, BRIGHT_MIX)
    }

    /// 暗色变体（`DimXxx`）：基础色向背景色混合。
    fn dim(&self, index: usize) -> Rgba {
        theme::mix(self.base[index], self.background, DIM_MIX)
    }

    /// 0-15 走主题 token，16-231 走立方体，232-255 走灰阶。
    fn indexed(&self, index: u8) -> Rgba {
        match index {
            0..=7 => self.base[index as usize],
            8..=15 => self.bright(index as usize - 8),
            16..=231 => {
                let n = index - 16;
                let levels = [0u8, 95, 135, 175, 215, 255];
                rgba_of((
                    levels[(n / 36) as usize],
                    levels[((n % 36) / 6) as usize],
                    levels[(n % 6) as usize],
                ))
            }
            _ => {
                let value = 8 + (index - 232) * 10;
                rgba_of((value, value, value))
            }
        }
    }

    /// 命名色 → 主题色。`Foreground`/`Background`/`Cursor` 与 `Dim*` 变体
    /// 都在这里显式落地；不要用 `named as u8` 取值，那会把 256+ 的变体折回
    /// 基础色（历史上 `DimRed` 会被当成 `Yellow`）。
    fn named(&self, named: NamedColor) -> Rgba {
        match named {
            NamedColor::Foreground | NamedColor::BrightForeground => self.foreground,
            NamedColor::DimForeground => self.dimmed_foreground,
            NamedColor::Background => self.background,
            NamedColor::Cursor => self.cursor,
            NamedColor::Black => self.base[0],
            NamedColor::Red => self.base[1],
            NamedColor::Green => self.base[2],
            NamedColor::Yellow => self.base[3],
            NamedColor::Blue => self.base[4],
            NamedColor::Magenta => self.base[5],
            NamedColor::Cyan => self.base[6],
            NamedColor::White => self.base[7],
            NamedColor::BrightBlack => self.bright(0),
            NamedColor::BrightRed => self.bright(1),
            NamedColor::BrightGreen => self.bright(2),
            NamedColor::BrightYellow => self.bright(3),
            NamedColor::BrightBlue => self.bright(4),
            NamedColor::BrightMagenta => self.bright(5),
            NamedColor::BrightCyan => self.bright(6),
            NamedColor::BrightWhite => self.bright(7),
            NamedColor::DimBlack => self.dim(0),
            NamedColor::DimRed => self.dim(1),
            NamedColor::DimGreen => self.dim(2),
            NamedColor::DimYellow => self.dim(3),
            NamedColor::DimBlue => self.dim(4),
            NamedColor::DimMagenta => self.dim(5),
            NamedColor::DimCyan => self.dim(6),
            NamedColor::DimWhite => self.dim(7),
        }
    }

    /// 语义颜色解算：加粗时 0-7 基础色自动取高亮 variant（标准终端行为）。
    fn resolve(&self, color: AlacColor, bold: bool) -> Rgba {
        match color {
            AlacColor::Named(named) => match named_base_index(named) {
                Some(index) if bold => self.bright(index),
                _ => self.named(named),
            },
            AlacColor::Indexed(index) => {
                self.indexed(if bold && index < 8 { index + 8 } else { index })
            }
            AlacColor::Spec(Rgb { r, g, b }) => rgba_of((r, g, b)),
        }
    }
}

/// 命名色是否是 0-7 的基础色（加粗高亮只对这 8 个色生效）。
fn named_base_index(named: NamedColor) -> Option<usize> {
    match named {
        NamedColor::Black => Some(0),
        NamedColor::Red => Some(1),
        NamedColor::Green => Some(2),
        NamedColor::Yellow => Some(3),
        NamedColor::Blue => Some(4),
        NamedColor::Magenta => Some(5),
        NamedColor::Cyan => Some(6),
        NamedColor::White => Some(7),
        _ => None,
    }
}

/// 单个单元格解析出的前景/底色（已处理 `INVERSE` / `HIDDEN` / `DIM`）。
fn resolve_cell_colors(
    foreground: AlacColor,
    background: AlacColor,
    flags: Flags,
    palette: &TermPalette,
) -> (Rgba, Rgba) {
    let mut fg = palette.resolve(foreground, flags.contains(Flags::BOLD));
    let bg = palette.resolve(background, false);
    if flags.contains(Flags::DIM) {
        fg = theme::mix(fg, bg, CELL_DIM_MIX);
    }
    if flags.contains(Flags::INVERSE) {
        return (bg, fg);
    }
    if flags.contains(Flags::HIDDEN) {
        return (bg, bg);
    }
    (fg, bg)
}

/// 光标呈现方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CursorStyle {
    /// 反色块。
    Block,
    /// 下划线。
    Underline,
    /// 竖线。
    Beam,
    /// 空心块。
    Hollow,
    /// 隐藏。
    Hidden,
}

impl From<CursorShape> for CursorStyle {
    fn from(shape: CursorShape) -> Self {
        match shape {
            CursorShape::Block => Self::Block,
            CursorShape::Underline => Self::Underline,
            CursorShape::Beam => Self::Beam,
            CursorShape::HollowBlock => Self::Hollow,
            CursorShape::Hidden => Self::Hidden,
        }
    }
}

// ---------------------------------------------------------------------------
// 会话层
// ---------------------------------------------------------------------------

/// 会话事件：PTY 输出字节，或子进程被回收的结果。
#[derive(Debug)]
pub enum SessionEvent {
    Output(Vec<u8>),
    /// 子进程已回收（正常退出、被信号杀死，或读取失败后的兜底状态）。
    Closed(TerminalExit),
}

/// 会话内部状态。会话句柄与升级/回收线程共享它，因此全部可跨线程。
struct SessionInner {
    writer: Mutex<Option<Box<dyn Write + Send>>>,
    master: Mutex<Option<Box<dyn MasterPty + Send>>>,
    /// 只用于停机兜底的信号句柄：与 `child` 分离，避免和阻塞在 `wait` 的
    /// reader 线程抢同一把锁。
    killer: Mutex<Option<Box<dyn ChildKiller + Send + Sync>>>,
    child: Mutex<Option<Box<dyn Child + Send + Sync>>>,
    /// 前台进程组 id（`portable-pty` 让子进程 `setsid`，因此它就是组长）。
    pgid: Option<i32>,
    /// 主端 reader 线程句柄：停止流程里由看门狗线程负责 join。
    reader: Mutex<Option<JoinHandle<()>>>,
    stop_requested: AtomicBool,
    lifecycle: Mutex<SessionLifecycle>,
    finished: Mutex<bool>,
    finished_signal: Condvar,
}

impl SessionInner {
    fn mark_finished(&self) {
        if let Ok(mut finished) = self.finished.lock() {
            *finished = true;
        }
        self.finished_signal.notify_all();
    }

    /// 有界等待子进程被回收；返回是否在期限内完成。
    fn wait_finished(&self, timeout: Duration) -> bool {
        let Ok(finished) = self.finished.lock() else {
            return true;
        };
        let (finished, result) = self
            .finished_signal
            .wait_timeout_while(finished, timeout, |finished| !*finished)
            .unwrap();
        *finished || result.timed_out()
    }

    /// 关闭 writer：Unix 下 portable-pty 会向 shell 写入换行 + EOT，
    /// 交互 shell 因此能自行退出。
    fn release_writer(&self) {
        if let Ok(mut guard) = self.writer.lock() {
            guard.take();
        }
    }

    /// 关闭主端：最后一个主端 fd 关闭后，slave 侧立刻收到 hangup，
    /// 阻塞在 `read` 的 reader 线程也会返回。
    fn release_master(&self) {
        if let Ok(mut guard) = self.master.lock() {
            guard.take();
        }
    }
}

/// Linux 原生 PTY 会话：拥有主端句柄、writer、子进程与 reader 线程。
///
/// 生命周期契约与 `run::process` 的受管进程一致：先温和终止、超过
/// [`SESSION_STOP_GRACE`] 升级为强杀，最后 join reader 线程。只 `drop` 主端
/// 句柄是不够的——那样拿不到退出码，也可能在子孙进程上留下残留。
pub struct TerminalSession {
    inner: Arc<SessionInner>,
    /// 展示用 shell 路径。
    shell: String,
}

impl TerminalSession {
    /// 打开 PTY 会话并起输出线程。返回会话与事件接收端。
    ///
    /// 线程只透传原始字节块；子进程回收也在同一线程完成，因此“输出停止”
    /// 与“进程已退出”必然同时被观察到，不会出现 PTY 已死但子进程未 wait
    /// 的窗口。
    pub fn new(
        dims: TermDims,
        working_dir: &str,
        shell: &str,
    ) -> anyhow::Result<(Self, mpsc::Receiver<SessionEvent>)> {
        let pty_system = native_pty_system();
        let pair = pty_system.openpty(pty_size(dims))?;

        let mut cmd = CommandBuilder::new(shell);
        if !working_dir.trim().is_empty() {
            cmd.cwd(working_dir);
        }
        for (key, value) in pty_environment(&std::env::vars().collect()) {
            cmd.env(key, value);
        }

        let child = pair.slave.spawn_command(cmd)?;
        let killer = child.clone_killer();
        let pgid = process_group_id(&pair.master, &child);
        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;

        let (tx, rx) = mpsc::channel::<SessionEvent>();
        let inner = Arc::new(SessionInner {
            writer: Mutex::new(Some(writer)),
            master: Mutex::new(Some(pair.master)),
            killer: Mutex::new(Some(killer)),
            child: Mutex::new(Some(child)),
            pgid,
            reader: Mutex::new(None),
            stop_requested: AtomicBool::new(false),
            lifecycle: Mutex::new(SessionLifecycle::new()),
            finished: Mutex::new(false),
            finished_signal: Condvar::new(),
        });
        if let Ok(mut lifecycle) = inner.lifecycle.lock() {
            lifecycle.apply(SessionEventKind::Spawned);
        }

        let worker = {
            let inner = inner.clone();
            thread::Builder::new()
                .name("lithe-terminal-pty".to_string())
                .spawn(move || {
                    pump_output(&inner, &mut reader, &tx);
                    let exit = reap_child(&inner);
                    if let Ok(mut lifecycle) = inner.lifecycle.lock() {
                        lifecycle.apply(SessionEventKind::Reaped(exit.clone()));
                    }
                    inner.mark_finished();
                    let _ = tx.send(SessionEvent::Closed(exit));
                })
                .map_err(|error| anyhow::anyhow!("Could not start PTY reader: {error}"))?
        };
        if let Ok(mut slot) = inner.reader.lock() {
            *slot = Some(worker);
        }

        Ok((
            Self {
                inner,
                shell: shell.to_string(),
            },
            rx,
        ))
    }

    /// 当前生命周期状态。
    pub fn state(&self) -> SessionState {
        self.inner
            .lifecycle
            .lock()
            .map(|lifecycle| lifecycle.state())
            .unwrap_or(SessionState::Closed)
    }

    /// 是否还能写字节/缩放。
    pub fn is_attached(&self) -> bool {
        self.state().is_attached()
    }

    /// 展示用 shell 路径。
    pub fn shell(&self) -> &str {
        &self.shell
    }

    /// 写入终端输入（键盘直输、粘贴、鼠标上报共用这一条路径）。
    pub fn write_bytes(&self, bytes: &[u8]) -> anyhow::Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        if !self.is_attached() {
            return Err(anyhow::anyhow!("Terminal session is not running"));
        }
        let mut guard = self
            .inner
            .writer
            .lock()
            .map_err(|_| anyhow::anyhow!("Terminal writer is unavailable"))?;
        let writer = guard
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("Terminal writer is closed"))?;
        writer.write_all(bytes)?;
        writer.flush()?;
        Ok(())
    }

    /// PTY 缩放：容器尺寸变化时调用，使 shell / 全屏 TUI 拿到最新行列数。
    pub fn resize(&self, dims: TermDims) {
        if !self.is_attached() {
            return;
        }
        if let Ok(guard) = self.inner.master.lock() {
            if let Some(master) = guard.as_ref() {
                let _ = master.resize(pty_size(dims));
            }
        }
    }

    /// 请求关闭会话：立即返回，退出与回收由看门狗线程完成。
    pub fn request_stop(&self) {
        if self.inner.stop_requested.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Ok(mut lifecycle) = self.inner.lifecycle.lock() {
            lifecycle.apply(SessionEventKind::StopRequested);
        }
        // 先断 writer：交互 shell 读到 EOT 自行退出，比等信号更快。
        self.inner.release_writer();
        let pgid = self.inner.pgid;
        let inner = self.inner.clone();
        thread::Builder::new()
            .name("lithe-terminal-stop".to_string())
            .spawn(move || {
                stop_session(&inner, pgid);
                if let Ok(mut slot) = inner.reader.lock() {
                    if let Some(worker) = slot.take() {
                        let _ = worker.join();
                    }
                }
            })
            .ok();
    }

    /// 关闭会话并有界等待回收（Drop 与显式关闭共用）。
    fn stop_and_reap(&self) {
        self.request_stop();
        if self
            .inner
            .wait_finished(SESSION_STOP_GRACE + SESSION_KILL_GRACE)
        {
            // 看门狗线程也会尝试 join；`take()` 保证只有一个赢家。
            if let Ok(mut slot) = self.inner.reader.lock() {
                if let Some(worker) = slot.take() {
                    let _ = worker.join();
                }
            }
        }
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        self.stop_and_reap();
    }
}

/// 看门狗线程的停止流程：温和终止 → 强杀 → 兜底直杀子进程。
///
/// 三步都用有界等待，任何一步都不阻塞调用方线程。
fn stop_session(inner: &Arc<SessionInner>, pgid: Option<i32>) {
    // 主端留着就无法把 hangup 送达 slave；停机阶段不再需要 resize。
    inner.release_master();
    if terminate_process_group(pgid, SESSION_STOP_GRACE) {
        return;
    }
    if terminate_process_group(pgid, SESSION_KILL_GRACE) {
        return;
    }
    // 进程组不可用或整组仍在退出：直接对子进程发信号。
    if let Ok(mut guard) = inner.killer.lock() {
        if let Some(killer) = guard.as_mut() {
            let _ = killer.kill();
        }
    }
    if inner.wait_finished(SESSION_KILL_GRACE) {
        return;
    }
    // 进程已收到 SIGKILL 仍不退出：不再无限等待，标记完成让 UI 继续，
    // 子进程由内核在父进程退出时一并回收。
    if let Ok(mut lifecycle) = inner.lifecycle.lock() {
        lifecycle.apply(SessionEventKind::Reaped(TerminalExit::Unknown));
    }
    inner.mark_finished();
}

fn pty_size(dims: TermDims) -> PtySize {
    PtySize {
        rows: dims.rows.clamp(MIN_ROWS, MAX_ROWS) as u16,
        cols: dims.cols.clamp(MIN_COLS, MAX_COLS) as u16,
        pixel_width: 0,
        pixel_height: 0,
    }
}

/// 取子进程进程组 id：优先用主端报告的前台进程组（`portable-pty` 让子进程
/// `setsid`，因此它就是组长），其次退回子进程 pid。
fn process_group_id(
    master: &Box<dyn MasterPty + Send>,
    child: &Box<dyn Child + Send + Sync>,
) -> Option<i32> {
    #[cfg(unix)]
    if let Some(pgid) = master.process_group_leader() {
        if pgid > 1 {
            return Some(pgid);
        }
    }
    let _ = master;
    child.process_id().and_then(|pid| i32::try_from(pid).ok())
}

/// reader 线程：透传输出字节，读端结束后回收子进程。
fn pump_output(
    inner: &Arc<SessionInner>,
    reader: &mut Box<dyn Read + Send>,
    tx: &mpsc::Sender<SessionEvent>,
) {
    let mut buffer = vec![0u8; READER_CHUNK];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                if tx
                    .send(SessionEvent::Output(buffer[..count].to_vec()))
                    .is_err()
                {
                    // 视图已释放：没人再消费输出，停止读；子进程由会话 Drop 拉起的
                    // 看门狗线程终止。
                    break;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    inner.release_writer();
}

/// 回收子进程：先非阻塞探测，再阻塞等待；看门狗线程负责兜底强杀。
fn reap_child(inner: &Arc<SessionInner>) -> TerminalExit {
    let Ok(mut guard) = inner.child.lock() else {
        return TerminalExit::Unknown;
    };
    let Some(child) = guard.as_mut() else {
        return TerminalExit::Unknown;
    };
    if let Ok(Some(status)) = child.try_wait() {
        return exit_of(status);
    }
    match child.wait() {
        Ok(status) => exit_of(status),
        Err(_) => TerminalExit::Unknown,
    }
}

fn exit_of(status: portable_pty::ExitStatus) -> TerminalExit {
    match status.signal() {
        Some(signal) if !signal.is_empty() => TerminalExit::Signal(signal.to_string()),
        _ => TerminalExit::Code(status.exit_code() as i32),
    }
}

// ---------------------------------------------------------------------------
// 视图层
// ---------------------------------------------------------------------------

/// 一个网格单元格的渲染数据（有序遍历 `display_iter` 时收集）。
#[derive(Clone, Copy, PartialEq)]
struct TermCell {
    /// 显示字符；`None` 表示宽字符占位格（只占宽度，不绘制）。
    c: Option<char>,
    fg: AlacColor,
    bg: AlacColor,
    flags: Flags,
    selected: bool,
}

/// 光标在一行中的落点。
#[derive(Debug, Clone, Copy)]
struct CursorPlacement {
    /// 该行是否就是光标行且光标可见（聚焦、未隐藏、视口在底部）。
    visible: bool,
    /// 光标列（单元格下标）。
    column: usize,
    style: CursorStyle,
    /// 闪烁相位（`false` 表示处于熄灭阶段）。
    phase: bool,
}

impl CursorPlacement {
    /// 光标是否真的画在下标为 `column` 的单元格上。
    fn covers(&self, column: usize) -> bool {
        self.visible && self.phase && column == self.column
    }

    /// 行尾之后是否需要补一个光标块。
    fn trailing(&self, rendered: usize) -> bool {
        self.visible && self.phase && self.column >= rendered
    }
}

/// 终端视图组件：单会话，键盘字符模式直输（IDEA 式交互）。
///
/// 网格引擎与交互能力全部来自上游 `alacritty_terminal`：本结构只负责调用
/// 它的 resize/scroll/selection/search API，并把结果投影成 GPUI 元素。
pub struct TerminalView {
    /// 当前会话；`None` 表示尚未创建或已被显式关闭（渲染空态）。
    session: Option<TerminalSession>,
    /// 会话工作目录（宿主项目切换时更新）。
    working_dir: String,
    /// 会话代号：每次新建/关闭自增，输出泵据此丢弃过期会话的字节。
    session_seq: u64,
    /// 是否仍允许在首个 prepaint 自动创建会话。自动创建只发生一次：失败或
    /// 用户显式关闭后都不再自动重试（否则每帧重开会话会打满 CPU）。
    auto_spawn_pending: bool,
    /// 单元格像素尺寸；每次 render 按当前字号实测写入。
    cell: CellMetrics,
    /// 最近一次已知的网格尺寸（行列）。
    size: TermDims,
    /// 网格内容区边界（窗口坐标）；由 `on_children_prepainted` 写入。
    grid_bounds: Rc<StdCell<Option<Bounds<Pixels>>>>,
    /// 上游引擎：唯一的终端语义来源。
    term: Term<VoidListener>,
    /// ANSI 解析器（`advance` 需要独占借用，故暂存取出再放回）。
    processor: Processor,
    focus_handle: FocusHandle,
    /// 正在拖拽选择时的选区类型。
    dragging: Option<SelectionType>,
    /// 终端内搜索状态。
    search: SearchState,
    /// 搜索输入框（懒创建，复用工作台唯一输入实现）。
    search_input: Option<SearchInput>,
    /// 搜索输入框事件订阅（必须与 `search_input` 同生命周期）。
    search_subscription: Option<Subscription>,
    /// 本次鼠标手势是否已向终端应用上报过按下（决定后续拖动/抬起是否上报）。
    mouse_reported: bool,
    /// 光标闪烁相位（`terminal_cursor_blink` 打开时由后台任务翻转）。
    cursor_phase: bool,
    /// 光标闪烁任务是否已在跑，避免重复启动定时任务。
    blink_task_running: bool,
}

impl TerminalView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let scrollback = settings::get(cx).terminal_scrollback.max(1);
        let size = TermDims {
            cols: BOOTSTRAP_COLS,
            rows: BOOTSTRAP_ROWS,
        };
        Self {
            session: None,
            working_dir,
            session_seq: 0,
            auto_spawn_pending: true,
            cell: CellMetrics {
                width: 8.0,
                height: 14.0,
            },
            size,
            grid_bounds: Rc::new(StdCell::new(None)),
            term: Term::new(
                Config {
                    scrolling_history: scrollback,
                    ..Config::default()
                },
                &size,
                VoidListener,
            ),
            processor: Processor::new(),
            focus_handle: cx.focus_handle(),
            dragging: None,
            search: SearchState::new(),
            search_input: None,
            search_subscription: None,
            mouse_reported: false,
            cursor_phase: true,
            blink_task_running: false,
        }
    }

    /// 当前会话是否可写。
    pub fn is_running(&self) -> bool {
        self.session
            .as_ref()
            .is_some_and(TerminalSession::is_attached)
    }

    /// 会话是否已存在（可能已退出，退出信息仍需展示）。
    pub fn has_session(&self) -> bool {
        self.session.is_some()
    }

    /// 已有会话时返回其状态。
    pub fn session_state(&self) -> SessionState {
        self.session
            .as_ref()
            .map(TerminalSession::state)
            .unwrap_or(SessionState::Closed)
    }

    /// 会话已经退出时给出退出码/信号，供状态区直接展示；仍在跑返回 `None`。
    pub fn session_exit(&self) -> Option<TerminalExit> {
        match self.session_state() {
            SessionState::Exited(exit) => Some(exit),
            _ => None,
        }
    }

    /// 会话 shell 路径（无会话时为空）。
    pub fn shell(&self) -> &str {
        self.session
            .as_ref()
            .map(TerminalSession::shell)
            .unwrap_or_default()
    }

    /// 视口是否停在底部（决定“回到底部”按钮是否可用）。
    pub fn is_at_bottom(&self) -> bool {
        self.term.grid().display_offset() == 0
    }

    /// 打开 PTY 会话并起主线程输出泵。已有会话、或自动创建闸门已关闭时不动。
    ///
    /// 自动路径由首帧 render 触发：PTY 先按引导尺寸启动，同一帧的 prepaint 立刻
    /// 用实测容器尺寸 resize 网格与 PTY，因此引导尺寸只存在一帧。
    fn ensure_session(&mut self, cx: &mut Context<Self>) {
        if self.session.is_some() || !self.auto_spawn_pending {
            return;
        }
        self.auto_spawn_pending = false;
        let shell = resolve_shell(&settings::get(cx).terminal_default_shell_id);
        let size = self.size;
        let working_dir = self.working_dir.clone();
        self.session_seq += 1;
        let seq = self.session_seq;
        match TerminalSession::new(size, &working_dir, &shell) {
            Ok((session, rx)) => {
                self.session = Some(session);
                let banner =
                    crate::i18n::menu_text(cx, "terminal.session").replace("{shell}", &shell);
                // 首行提示直接画进网格（换行落行）。
                self.advance(format!("{banner}\r\n").as_bytes());
                Self::spawn_pump(rx, seq, cx);
            }
            Err(error) => {
                tracing::warn!("failed to open terminal pty session: {error}");
                let text = crate::i18n::menu_text(cx, "terminal.unavailable");
                self.advance(format!("{text}: {error}\r\n").as_bytes());
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
    ///
    /// 阻塞的 `recv` 放在后台线程，UI 线程只做 `advance`；会话代号变化后
    /// 旧泵立即退出，旧会话的字节不会污染新网格。
    fn spawn_pump(rx: mpsc::Receiver<SessionEvent>, seq: u64, cx: &mut Context<Self>) {
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
            let Some(event) = next else {
                break;
            };
            let alive = this
                .update(cx, |view, cx| view.handle_session_event(seq, event, cx))
                .unwrap_or(false);
            if !alive {
                break;
            }
        })
        .detach();
    }

    /// 处理一条会话事件；返回是否继续泵（会话已结束或被替换则停止）。
    fn handle_session_event(
        &mut self,
        seq: u64,
        event: SessionEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        if seq != self.session_seq {
            return false;
        }
        match event {
            SessionEvent::Output(bytes) => {
                self.advance(&bytes);
                cx.notify();
                true
            }
            SessionEvent::Closed(exit) => {
                self.report_exit(exit, cx);
                false
            }
        }
    }

    /// 把子进程退出结果写进网格，让用户看到会话为什么停了。
    fn report_exit(&mut self, exit: TerminalExit, cx: &mut Context<Self>) {
        let key = match &exit {
            TerminalExit::Code(_) => "terminal.exitedCode",
            TerminalExit::Signal(_) => "terminal.signalled",
            TerminalExit::Unknown => "terminal.exitUnknown",
        };
        let text = crate::i18n::menu_text(cx, key).replace("{detail}", &exit.detail());
        self.advance(format!("{text}\r\n").as_bytes());
        cx.notify();
    }

    /// 新建会话：先关闭旧会话（回收子进程），再按当前尺寸与工作目录重开。
    pub fn restart(&mut self, cx: &mut Context<Self>) {
        self.teardown_session();
        self.reset_grid(cx);
        self.open_session(cx);
    }

    /// 显式新建会话（忽略自动创建闸门，供空态按钮与程序化命令使用）。
    fn open_session(&mut self, cx: &mut Context<Self>) {
        self.auto_spawn_pending = true;
        self.ensure_session(cx);
    }

    /// 关闭会话：回收子进程并回到空态，且不再自动重建（面板是否折叠由宿主决定）。
    pub fn close_session(&mut self, cx: &mut Context<Self>) {
        self.teardown_session();
        self.reset_grid(cx);
        self.auto_spawn_pending = false;
        cx.notify();
    }

    /// 丢弃当前会话句柄（进程组终止与 reader 回收交给后台线程，见
    /// [`TerminalSession::stop_and_reap`] 的有界等待）。
    fn teardown_session(&mut self) {
        self.session_seq += 1;
        if let Some(session) = self.session.take() {
            // 句柄的 `Drop` 会有界等待子进程回收，不能占用 UI 线程；交给一次
            // 性后台线程立即 drop，效果与原地 drop 相同。
            thread::Builder::new()
                .name("lithe-terminal-reap".to_string())
                .spawn(move || drop(session))
                .ok();
        }
        self.dragging = None;
        self.mouse_reported = false;
    }

    /// 重建上游网格并清空搜索态（回滚缓冲、选择、命中列表都归零）。
    fn reset_grid(&mut self, cx: &mut Context<Self>) {
        let scrollback = settings::get(cx).terminal_scrollback.max(1);
        self.term = Term::new(
            Config {
                scrolling_history: scrollback,
                ..Config::default()
            },
            &self.size,
            VoidListener,
        );
        self.processor = Processor::new();
        self.search.clear();
        self.dragging = None;
        self.mouse_reported = false;
        cx.notify();
    }

    /// 切换工作目录。项目切换后旧 shell 的 cwd 与环境已过期，按 IDE 语义
    /// 重启会话（`cd` 命令只适用于“打开某个子目录”，不适用于换项目）。
    pub fn set_working_dir(&mut self, dir: String, cx: &mut Context<Self>) {
        let dir = dir.trim().to_string();
        if dir.is_empty() || dir == self.working_dir {
            return;
        }
        self.working_dir = dir;
        if self.session.is_some() {
            self.restart(cx);
        } else {
            cx.notify();
        }
    }

    /// 清屏（等价于 shell `clear`：擦除可见区，保留回滚）。
    pub fn clear(&mut self, cx: &mut Context<Self>) {
        if self.has_session() {
            self.advance(b"\x1b[2J\x1b[H");
        }
        cx.notify();
    }

    /// 程序化发送命令（宿主调用，如打开目录）：原文 + 换行。
    pub fn send_command(&mut self, cmd: &str, cx: &mut Context<Self>) {
        // 会话被显式关闭过时命令无处可去，这里按用户意图重新开会话。
        self.open_session(cx);
        if !self.is_running() {
            return;
        }
        let mut full = cmd.to_string();
        full.push('\n');
        if let Some(session) = &self.session {
            let _ = session.write_bytes(full.as_bytes());
        }
        self.scroll_to_bottom();
        cx.notify();
    }

    /// 视口滚到底部（回到底部动作、键盘输入后自动跟随）。
    pub fn scroll_to_bottom(&mut self) {
        self.term.scroll_display(Scroll::Bottom);
    }

    /// 依据容器实测尺寸同步网格与 PTY（上游 reflow 由 `Term::resize` 完成）。
    /// 返回尺寸是否发生变化。
    fn sync_size(&mut self, bounds: Bounds<Pixels>, cx: &mut Context<Self>) -> bool {
        let Some(dims) = self.cell.grid_dims(bounds.size) else {
            return false;
        };
        if dims == self.size {
            return false;
        }
        self.size = dims;
        self.term.resize(dims);
        if let Some(session) = &self.session {
            session.resize(dims);
        }
        cx.notify();
        true
    }

    /// 窗口坐标 → 网格点（含回滚偏移）；越界返回 `None`。
    fn grid_point_at(&self, position: Point<Pixels>) -> Option<GridPoint> {
        let bounds = self.grid_bounds.get()?;
        viewport_to_grid_point(
            f32::from(position.x) - f32::from(bounds.origin.x),
            f32::from(position.y) - f32::from(bounds.origin.y),
            self.cell,
            self.size,
            self.term.grid().display_offset(),
        )
    }

    /// 把输入字节写入 PTY，并把视口带回底部（IDEA/xterm 行为：一旦开始
    /// 交互就该看到最新输出）。
    fn send_to_pty(&mut self, bytes: &[u8]) {
        let bracketed = self.term.mode().contains(TermMode::BRACKETED_PASTE);
        let payload = if bracketed && bytes.len() > 1 {
            // 上游开启 bracketed paste 后必须成对包裹，否则程序会把粘贴
            // 当成逐字输入执行。
            let mut payload = vec![0x1b, b'[', b'2', b'0', b'0', b'~'];
            payload.extend_from_slice(bytes);
            payload.extend_from_slice(b"\x1b[201~");
            payload
        } else {
            bytes.to_vec()
        };
        let written = self
            .session
            .as_ref()
            .is_some_and(|session| session.write_bytes(&payload).is_ok());
        if written {
            self.scroll_to_bottom();
        }
    }

    /// 复制当前选择到系统剪贴板；无选择返回 false。
    fn copy_selection(&self, cx: &mut App) -> bool {
        let Some(text) = self.term.selection_to_string() else {
            return false;
        };
        if text.is_empty() {
            return false;
        }
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        true
    }

    /// 从系统剪贴板粘贴到 PTY（读不到或为空则忽略）。
    fn paste_clipboard(&mut self, cx: &mut App) {
        let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) else {
            return;
        };
        if text.is_empty() {
            return;
        }
        // 剪贴板里的 CRLF 会让部分交互程序吞掉后续行，统一成 LF。
        let normalized = text.replace("\r\n", "\n");
        self.send_to_pty(normalized.as_bytes());
    }

    /// 打开终端内搜索：复用工作台唯一输入实现并聚焦。
    pub fn open_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.search_input.is_none() {
            let search = SearchInput::new(
                crate::i18n::menu_text(cx, "terminal.searchPlaceholder"),
                window,
                cx,
            );
            // 订阅必须与输入框同生命周期，否则事件立即失效。
            self.search_subscription = Some(search.subscribe(cx, |this, event, cx| match event {
                InputEvent::Change => {
                    let value = this
                        .search_input
                        .as_ref()
                        .map(|input| input.value(cx))
                        .unwrap_or_default();
                    this.apply_search_query(value, cx);
                }
                InputEvent::PressEnter { shift, .. } => this.step_search(!shift, cx),
                // 失焦不抢焦点：等用户点击网格或按关闭按钮，避免打字中途被夺走。
                InputEvent::Focus | InputEvent::Blur => {}
            }));
            self.search_input = Some(search);
        }
        let search = self
            .search_input
            .as_ref()
            .expect("search input just created");
        // 打开即复位为空查询并聚焦一次；不要每帧抢焦点。
        search.set_value("", window, cx);
        self.search.clear();
        self.term.selection = None;
        search.focus(window, cx);
        cx.notify();
    }

    /// 关闭搜索栏并清除搜索态高亮，焦点回到网格。
    pub fn close_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search.clear();
        self.term.selection = None;
        self.search_subscription = None;
        self.search_input = None;
        window.focus(&self.focus_handle, cx);
        cx.notify();
    }

    /// 搜索栏是否可见。
    fn search_visible(&self) -> bool {
        self.search_input.is_some()
    }

    /// 查询串变化：重建上游正则、重扫命中并高亮首个。
    fn apply_search_query(&mut self, query: String, cx: &mut Context<Self>) {
        if query == self.search.query {
            return;
        }
        self.search.set_query(&self.term, query);
        self.highlight_current_match();
        cx.notify();
    }

    /// 上一个/下一个命中：序号环绕 + 上游滚动 + 用 selection 高亮。
    fn step_search(&mut self, forward: bool, cx: &mut Context<Self>) {
        if self.search.is_empty() {
            return;
        }
        if self.search.total() == 0 {
            // 上一次查询判定无命中，而输出可能已经变化，重扫一次。
            self.search.jump_to_first(&self.term);
        }
        self.search.step(forward);
        self.highlight_current_match();
        cx.notify();
    }

    fn highlight_current_match(&mut self) {
        let Some(found) = self.search.current_match() else {
            self.term.selection = None;
            return;
        };
        self.term.scroll_to_point(*found.start());
        let mut selection = Selection::new(SelectionType::Simple, *found.start(), Side::Left);
        selection.update(*found.end(), Side::Right);
        self.term.selection = Some(selection);
    }

    /// 应用按键动作；返回是否已消费（未消费则不阻止全局快捷键）。
    fn apply_key_action(
        &mut self,
        action: KeyAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        match action {
            KeyAction::Send(bytes) => self.send_to_pty(&bytes),
            KeyAction::Copy => {
                self.copy_selection(cx);
            }
            KeyAction::Paste => self.paste_clipboard(cx),
            KeyAction::OpenSearch => self.open_search(window, cx),
            KeyAction::Scroll(lines) => {
                self.term.scroll_display(Scroll::Delta(lines as i32));
            }
            KeyAction::ScrollToBottom => self.scroll_to_bottom(),
            KeyAction::Passthrough => return false,
        }
        cx.notify();
        true
    }

    /// 开始一次选择（单击 simple / 双击 semantic / 三击 lines）。
    fn begin_selection(&mut self, point: GridPoint, ty: SelectionType) {
        self.term.selection = Some(Selection::new(ty, point, Side::Left));
        self.dragging = Some(ty);
    }

    /// 更新拖拽中的选择终点。
    fn update_selection(&mut self, point: GridPoint) {
        if let Some(selection) = self.term.selection.as_mut() {
            selection.update(point, Side::Right);
        }
    }

    /// 鼠标事件是否应交给终端应用而不是本地选择。
    fn report_mouse(&mut self, report: MouseReport, position: Point<Pixels>) -> bool {
        if !mouse_report_enabled(report, *self.term.mode()) {
            return false;
        }
        let Some(point) = self.grid_point_at(position) else {
            return false;
        };
        let sgr = self.term.mode().contains(TermMode::SGR_MOUSE);
        let bytes = encode_mouse_report(report, point, self.term.grid().display_offset(), sgr);
        self.send_to_pty(&bytes);
        true
    }

    /// 键盘输入入口。返回是否已消费（消费则阻止冒泡到全局快捷键）。
    fn handle_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.search_visible() {
            // 搜索栏打开时字符归输入框（正常路径下焦点在输入框，这里走不到）。
            // 保留这道闸门：一旦焦点意外留在网格上，也不能把搜索期按键直输 PTY。
            return false;
        }
        let action = map_key(
            &event.keystroke.key,
            event.keystroke.key_char.as_deref(),
            KeyModifiers::from(&event.keystroke.modifiers),
            *self.term.mode(),
            self.size.rows,
        );
        self.apply_key_action(action, window, cx)
    }

    /// 光标闪烁任务：仅在设置打开且会话存在时翻转相位；条件不再满足时
    /// 自行退出，不会留下常驻定时任务。
    fn spawn_blink(cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(CURSOR_BLINK_INTERVAL).await;
            let keep = this
                .update(cx, |view, cx| {
                    if !view.blink_task_running || !view.has_session() {
                        view.blink_task_running = false;
                        return false;
                    }
                    view.cursor_phase = !view.cursor_phase;
                    cx.notify();
                    true
                })
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }
}

impl Render for TerminalView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 单元格基准宽度：等宽字体下用上游 `em_layout_width` 实测（随字号变化）。
        let font_size = px(settings::get(cx).terminal_font_size);
        self.cell = CellMetrics::measure(window, font_size);
        let blink_enabled = settings::get(cx).terminal_cursor_blink;
        if blink_enabled && !self.blink_task_running {
            self.blink_task_running = true;
            Self::spawn_blink(cx);
        } else if !blink_enabled {
            self.blink_task_running = false;
        }

        // 没有会话就开一次（首帧用引导尺寸，本帧 prepaint 立刻按实测尺寸
        // resize 网格与 PTY；之后一律用已实测的尺寸）。自动创建只尝试一次，
        // 失败或用户显式关闭后不会每帧重试。
        if !self.has_session() {
            self.ensure_session(cx);
        }

        let palette = TermPalette::from_theme();
        let focused = self.focus_handle.is_focused(window);
        let display_offset = self.term.grid().display_offset();

        // 可见区按行分组（`display_iter` 即当前视口，已含回滚偏移）。
        let content = self.term.renderable_content();
        let selection = content.selection;
        let cursor_line = content.cursor.point.line.0;
        let cursor_col = content.cursor.point.column.0;
        let cursor_style = CursorStyle::from(content.cursor.shape);
        // 上滚时不画光标：它已经不在视口里，画出来会指向错误的行。
        let cursor_visible = focused && cursor_style != CursorStyle::Hidden && display_offset == 0;
        let mut rows: Vec<(i32, Vec<TermCell>)> = Vec::new();
        for indexed in content.display_iter {
            let line = indexed.point.line.0;
            if rows.last().map(|(number, _)| *number) != Some(line) {
                rows.push((line, Vec::new()));
            }
            let cell = indexed.cell;
            let selected = selection
                .as_ref()
                .is_some_and(|range| range.contains(indexed.point));
            rows.last_mut()
                .expect("rows non-empty after push")
                .1
                .push(TermCell {
                    // 宽字符的占位格只占宽度，不绘制字符。
                    c: if cell
                        .flags
                        .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                    {
                        None
                    } else {
                        Some(cell.c)
                    },
                    fg: cell.fg,
                    bg: cell.bg,
                    flags: cell.flags,
                    selected,
                });
        }
        let cursor_phase = self.cursor_phase;

        let cell = self.cell;
        let rendered_rows: Vec<gpui_kit::AnyElement> = rows
            .into_iter()
            .map(|(line, cells)| {
                render_term_row(
                    line,
                    &cells,
                    CursorPlacement {
                        visible: cursor_visible && line == cursor_line,
                        column: cursor_col,
                        style: cursor_style,
                        phase: cursor_phase,
                    },
                    &palette,
                    cell.width,
                    cell.height,
                )
            })
            .collect();

        let grid = div()
            .flex_1()
            .w_full()
            .min_h_0()
            .overflow_hidden()
            .pt(px(GRID_PADDING))
            .pl(px(GRID_PADDING))
            .pr(px(GRID_PADDING))
            .text_size(font_size)
            .font_family("monospace")
            .children(rendered_rows);

        // 网格容器：唯一子元素，因此 prepaint 给出的首个子边界就是网格容器
        // 的实测边界。在这里直接驱动 resize，避免“先按引导尺寸渲染、下一帧才
        // resize”的滞后（折叠/展开、窗口缩放都当帧生效）。
        let bounds_slot = self.grid_bounds.clone();
        let weak = cx.weak_entity();
        let grid_with_bounds = div()
            .flex_1()
            .w_full()
            .min_h_0()
            .on_children_prepainted(move |bounds, _window, cx| {
                let Some(first) = bounds.first().copied() else {
                    return;
                };
                bounds_slot.set(Some(first));
                let _ = weak.update(cx, |view, cx| {
                    view.sync_size(first, cx);
                });
            })
            .child(grid);

        let body: gpui_kit::AnyElement = if self.has_session() {
            let search_bar = if self.search_visible() {
                Some(self.render_search_bar(cx))
            } else {
                None
            };
            div()
                .flex_1()
                .w_full()
                .min_h_0()
                .id("terminal-grid")
                .track_focus(&self.focus_handle)
                .cursor_text()
                .on_click(cx.listener(|this, _event, window, cx| {
                    if this.search_visible() {
                        this.close_search(window, cx);
                    }
                    window.focus(&this.focus_handle, cx);
                }))
                .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                    if this.handle_key(event, window, cx) {
                        cx.stop_propagation();
                    }
                }))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|this, event: &MouseDownEvent, window, cx| {
                        if this.search_visible() {
                            this.close_search(window, cx);
                        }
                        window.focus(&this.focus_handle, cx);
                        if this.report_mouse(MouseReport::Press(0), event.position) {
                            this.mouse_reported = true;
                            return;
                        }
                        let Some(point) = this.grid_point_at(event.position) else {
                            return;
                        };
                        let ty = match event.click_count {
                            0 | 1 => SelectionType::Simple,
                            2 => SelectionType::Semantic,
                            _ => SelectionType::Lines,
                        };
                        this.begin_selection(point, ty);
                        cx.notify();
                    }),
                )
                .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _window, cx| {
                    // 拖动上报只在“已上报按下”且按键仍按住时发，否则全屏 TUI
                    // 会被鼠标移动刷屏。
                    if this.mouse_reported
                        && event.pressed_button.is_some()
                        && this.report_mouse(MouseReport::Drag(0), event.position)
                    {
                        return;
                    }
                    if this.dragging.is_none() {
                        return;
                    }
                    if let Some(point) = this.grid_point_at(event.position) {
                        this.update_selection(point);
                        cx.notify();
                    }
                }))
                .on_mouse_up(
                    MouseButton::Left,
                    cx.listener(|this, event: &MouseUpEvent, _window, cx| {
                        let reported = this.mouse_reported;
                        this.mouse_reported = false;
                        this.dragging = None;
                        if reported {
                            this.report_mouse(MouseReport::Release(0), event.position);
                        }
                        cx.notify();
                    }),
                )
                .on_mouse_down(
                    MouseButton::Right,
                    cx.listener(|this, _event: &MouseDownEvent, window, cx| {
                        // 右键粘贴（IDEA 终端习惯），不落本地选择。
                        cx.stop_propagation();
                        this.paste_clipboard(cx);
                        window.focus(&this.focus_handle, cx);
                    }),
                )
                .on_scroll_wheel(cx.listener(|this, event: &ScrollWheelEvent, _window, cx| {
                    if this.scroll_wheel(event) {
                        cx.notify();
                    }
                }))
                // 浮层搜索栏必须排在网格之后：GPUI 按绘制顺序逆序命中，
                // 否则网格会盖住搜索条。
                .child(grid_with_bounds)
                .when_some(search_bar, |el, bar| el.child(bar))
                .into_any_element()
        } else {
            self.render_closed_state(cx)
        };

        v_flex()
            .size_full()
            .bg(ThemeColors::background())
            .child(body)
    }
}

impl TerminalView {
    /// 滚轮 → 视口行数。Shift+滚轮在 Linux 上是横向手势，终端按行处理。
    fn scroll_wheel(&mut self, event: &ScrollWheelEvent) -> bool {
        let shift = event.modifiers.shift;
        let lines = match event.delta {
            ScrollDelta::Lines(point) => wheel_axis(shift, f64::from(point.x), f64::from(point.y)),
            ScrollDelta::Pixels(point) => {
                let axis = wheel_axis(shift, f64::from(point.x), f64::from(point.y));
                axis / self.cell.height as f64
            }
        };
        let delta = lines.round() as isize;
        if delta == 0 {
            return false;
        }
        self.term.scroll_display(Scroll::Delta(delta as i32));
        true
    }

    /// 无会话空态：给出明确的下一步（新建会话），不留空白面板。
    fn render_closed_state(&self, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        v_flex()
            .flex_1()
            .w_full()
            .min_h_0()
            .items_center()
            .justify_center()
            .gap_3()
            .child(
                div()
                    .text_sm()
                    .text_color(ThemeColors::text_muted())
                    .child(crate::i18n::menu_text(cx, "terminal.closed")),
            )
            .child(
                Button::new("terminal-open")
                    .small()
                    .primary()
                    .icon(gpui_kit::assets::IconName::Plus)
                    .label(crate::i18n::menu_text(cx, "menu.newTerminal"))
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.open_session(cx);
                    })),
            )
            .into_any_element()
    }

    /// 渲染搜索栏（终端内搜索，对齐 Windows 终端搜索条：浮层 + 计数 +
    /// 上/下一个 + 关闭）。做成浮层而不是挤占一行高度，打开/关闭搜索不会触发
    /// 终端 resize 与全屏 TUI 重排。输入框复用 [`SearchInput`]，不在终端里
    /// 另写一套。
    fn render_search_bar(&self, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let search = self.search_input.as_ref().expect("search bar needs input");
        let label = self.search.label();
        let can_step = self.search.total() > 0;
        h_flex()
            .absolute()
            .top_2()
            .right_2()
            .w(px(360.0))
            .items_center()
            .gap_2()
            .px_2()
            .py_1()
            .bg(ThemeColors::bg_tab_bar())
            .border_1()
            .border_color(ThemeColors::border())
            .rounded_md()
            .shadow_lg()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                // Esc 关闭搜索栏：输入框自己没有这个动作，由搜索条兜底。
                if event.keystroke.key.as_str() == "escape" {
                    this.close_search(window, cx);
                    cx.stop_propagation();
                }
            }))
            .child(search.element())
            .child(
                div()
                    .flex_shrink_0()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child(label),
            )
            .child(
                Button::new("terminal-search-prev")
                    .small()
                    .ghost()
                    .icon(gpui_kit::assets::IconName::ChevronUp)
                    .tooltip(crate::i18n::menu_text(cx, "terminal.searchPrevious"))
                    .disabled(!can_step)
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.step_search(false, cx);
                    })),
            )
            .child(
                Button::new("terminal-search-next")
                    .small()
                    .ghost()
                    .icon(gpui_kit::assets::IconName::ChevronDown)
                    .tooltip(crate::i18n::menu_text(cx, "terminal.searchNext"))
                    .disabled(!can_step)
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.step_search(true, cx);
                    })),
            )
            .child(
                Button::new("terminal-search-close")
                    .small()
                    .ghost()
                    .icon(gpui_kit::assets::IconName::X)
                    .tooltip(crate::i18n::menu_text(cx, "terminal.searchClose"))
                    .on_click(cx.listener(|this, _event, window, cx| {
                        this.close_search(window, cx);
                    })),
            )
            .into_any_element()
    }
}

/// 渲染网格一行：同样式字符合并为一段；选中字符用选区底色；光标按上游
/// `CursorShape` 呈现。每段用固定像素宽度（`字符数 × cell_width`）保证
/// 等宽对齐，鼠标命中换算依赖同一套单元格尺寸。
fn render_term_row(
    line: i32,
    cells: &[TermCell],
    cursor: CursorPlacement,
    palette: &TermPalette,
    cell_width: f32,
    line_height: f32,
) -> gpui_kit::AnyElement {
    let mut row = h_flex()
        .id(format!("term-row-{line}"))
        .w_full()
        .h(px(line_height))
        .flex_shrink_0()
        .items_center()
        .whitespace_nowrap()
        .font_family("monospace");
    if cells.is_empty() {
        if cursor.trailing(0) {
            row = row.child(cursor_block(
                palette,
                " ".to_string(),
                cell_width,
                cursor.style,
            ));
        }
        return row.into_any_element();
    }

    let mut index = 0usize;
    while index < cells.len() {
        let cell = cells[index];
        if cursor.covers(index) {
            let (fg, bg) = resolve_cell_colors(cell.fg, cell.bg, cell.flags, palette);
            row = row.child(
                div()
                    .flex_shrink_0()
                    .w(px(cell_width))
                    .text_color(bg)
                    .bg(fg)
                    .child(cell.c.map(|c| c.to_string()).unwrap_or_default()),
            );
            index += 1;
            continue;
        }

        // 合并同 (fg,bg,flags,selected) 的后续字符。
        let mut text = String::new();
        let mut width = 0usize;
        while index + width < cells.len() {
            let next = cells[index + width];
            if cursor.covers(index + width) {
                break;
            }
            if next.fg != cell.fg
                || next.bg != cell.bg
                || next.flags != cell.flags
                || next.selected != cell.selected
            {
                break;
            }
            // 宽字符占位格也要占一格宽度，但不产生字符。
            if let Some(c) = next.c {
                text.push(c);
            }
            width += 1;
        }
        let (fg, bg) = resolve_cell_colors(cell.fg, cell.bg, cell.flags, palette);
        let mut segment = div()
            .flex_shrink_0()
            .w(px(cell_width * width as f32))
            .text_color(fg)
            .when(cell.selected, |el| el.bg(palette.selection))
            .when(
                !cell.selected && cell.bg != AlacColor::Named(NamedColor::Background),
                |el| el.bg(bg),
            );
        if cell.flags.contains(Flags::BOLD) {
            segment = segment.font_weight(FontWeight::BOLD);
        }
        if cell.flags.contains(Flags::ITALIC) {
            segment = segment.italic();
        }
        if cell.flags.intersects(Flags::ALL_UNDERLINES) {
            segment = segment.underline();
        }
        if cell.flags.contains(Flags::STRIKEOUT) {
            segment = segment.line_through();
        }
        row = row.child(segment.child(text));
        index += width;
    }

    // 光标超出已给出单元格（行尾之后）：补一个光标块。
    if cursor.trailing(cells.len()) {
        row = row.child(cursor_block(
            palette,
            " ".to_string(),
            cell_width,
            cursor.style,
        ));
    }

    row.into_any_element()
}

/// 光标块：反色（前景当底、背景当字）；下划线/竖线/空心三种形状按上游
/// `CursorShape` 用边框表达。
fn cursor_block(
    palette: &TermPalette,
    text: String,
    cell_width: f32,
    style: CursorStyle,
) -> gpui_kit::AnyElement {
    let block = div()
        .flex_shrink_0()
        .w(px(cell_width))
        .h_full()
        .text_color(palette.background)
        .bg(palette.cursor)
        .child(text);
    match style {
        CursorStyle::Block | CursorStyle::Hidden => block.into_any_element(),
        CursorStyle::Underline => block
            .border_b_1()
            .border_color(palette.cursor)
            .into_any_element(),
        CursorStyle::Beam => block
            .border_l_1()
            .border_color(palette.cursor)
            .into_any_element(),
        CursorStyle::Hollow => block
            .border_1()
            .border_color(palette.cursor)
            .text_color(palette.cursor)
            .bg(palette.background)
            .into_any_element(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dims(cols: usize, rows: usize) -> TermDims {
        TermDims { cols, rows }
    }

    fn cell() -> CellMetrics {
        CellMetrics {
            width: 8.0,
            height: 16.0,
        }
    }

    fn mods(control: bool, alt: bool, shift: bool, platform: bool) -> KeyModifiers {
        KeyModifiers {
            control,
            alt,
            shift,
            platform,
        }
    }

    fn plain() -> KeyModifiers {
        mods(false, false, false, false)
    }

    /// 构造带输出的测试终端（复用与生产一致的解析路径）。
    fn term_with_output(bytes: &[u8]) -> Term<VoidListener> {
        let mut term = Term::new(
            Config {
                scrolling_history: 100,
                ..Config::default()
            },
            &dims(40, 10),
            VoidListener,
        );
        let mut processor: Processor = Processor::new();
        processor.advance(&mut term, bytes);
        term
    }

    // ---- 坐标换算 ----

    /// 网格左上角第一格：局部坐标需扣除内边距。
    #[test]
    fn maps_top_left_corner_to_origin_cell() {
        let point = viewport_to_grid_point(GRID_PADDING, GRID_PADDING, cell(), dims(80, 24), 0)
            .expect("top-left must hit a cell");
        assert_eq!(point.line.0, 0);
        assert_eq!(point.column.0, 0);
    }

    /// 内边距内的坐标不算命中，避免选中出现偏移半格。
    #[test]
    fn rejects_point_inside_padding() {
        assert!(
            viewport_to_grid_point(GRID_PADDING - 0.5, GRID_PADDING, cell(), dims(80, 24), 0)
                .is_none()
        );
        assert!(
            viewport_to_grid_point(GRID_PADDING, GRID_PADDING - 0.5, cell(), dims(80, 24), 0)
                .is_none()
        );
    }

    /// 列/行按单元格尺寸取整：第 n 格覆盖 [n*w, (n+1)*w)。
    #[test]
    fn rounds_down_to_containing_cell() {
        let point = viewport_to_grid_point(
            GRID_PADDING + cell().width * 3.0 + 1.0,
            GRID_PADDING + cell().height * 2.0 + 1.0,
            cell(),
            dims(80, 24),
            0,
        )
        .expect("inside grid");
        assert_eq!(point.column.0, 3);
        assert_eq!(point.line.0, 2);
    }

    /// 越出网格列/行的坐标不命中。
    #[test]
    fn rejects_out_of_bounds() {
        let cols = 10;
        let rows = 5;
        let beyond_cols = viewport_to_grid_point(
            GRID_PADDING + cell().width * cols as f32,
            GRID_PADDING,
            cell(),
            dims(cols, rows),
            0,
        );
        assert!(beyond_cols.is_none());
        let beyond_rows = viewport_to_grid_point(
            GRID_PADDING,
            GRID_PADDING + cell().height * rows as f32,
            cell(),
            dims(cols, rows),
            0,
        );
        assert!(beyond_rows.is_none());
    }

    /// 回滚偏移把视口行还原成网格行：上滚 3 行后，视口首行是网格 -3 行。
    #[test]
    fn applies_scrollback_offset_to_viewport_line() {
        let point = viewport_to_grid_point(GRID_PADDING, GRID_PADDING, cell(), dims(80, 24), 3)
            .expect("top-left with scrollback");
        assert_eq!(point.line.0, -3);
        assert_eq!(point.column.0, 0);
    }

    /// 容器尺寸 → 网格行列数；容器未布局完成时不产出尺寸，极小容器不退化。
    #[test]
    fn grid_dims_follow_measured_container() {
        let metrics = cell();
        let size = Size {
            width: px(GRID_PADDING * 2.0 + metrics.width * 40.0),
            height: px(GRID_PADDING * 2.0 + metrics.height * 12.0),
        };
        assert_eq!(metrics.grid_dims(size), Some(dims(40, 12)));
        assert_eq!(
            metrics.grid_dims(Size {
                width: px(0.0),
                height: px(0.0)
            }),
            None
        );
        assert_eq!(
            metrics.grid_dims(Size {
                width: px(GRID_PADDING * 2.0 + 1.0),
                height: px(GRID_PADDING * 2.0 + 1.0)
            }),
            Some(dims(MIN_COLS, MIN_ROWS))
        );
        // 超大容器必须被钳住，避免给 PTY 报一个荒谬的行列数。
        assert_eq!(
            metrics.grid_dims(Size {
                width: px(100_000.0),
                height: px(100_000.0)
            }),
            Some(dims(MAX_COLS, MAX_ROWS))
        );
    }

    // ---- 生命周期状态机 ----

    /// 正常路径：Closed → Running → Stopping → Exited(码)。
    #[test]
    fn lifecycle_runs_from_spawn_to_exit_code() {
        let mut lifecycle = SessionLifecycle::new();
        assert_eq!(lifecycle.state(), SessionState::Closed);
        assert_eq!(
            lifecycle.apply(SessionEventKind::Spawned),
            SessionState::Running
        );
        assert_eq!(
            lifecycle.apply(SessionEventKind::StopRequested),
            SessionState::Stopping
        );
        assert_eq!(
            lifecycle.apply(SessionEventKind::Reaped(TerminalExit::Code(0))),
            SessionState::Exited(TerminalExit::Code(0))
        );
    }

    /// 停止请求是幂等的，重复请求不得把状态退回 Running。
    #[test]
    fn stop_request_is_idempotent() {
        let mut lifecycle = SessionLifecycle::new();
        lifecycle.apply(SessionEventKind::Spawned);
        lifecycle.apply(SessionEventKind::StopRequested);
        assert_eq!(
            lifecycle.apply(SessionEventKind::StopRequested),
            SessionState::Stopping
        );
    }

    /// 前台程序自己退出时不经过 Stopping，Running 直接到 Exited(信号)。
    #[test]
    fn spontaneous_exit_keeps_signal_detail() {
        let mut lifecycle = SessionLifecycle::new();
        lifecycle.apply(SessionEventKind::Spawned);
        let exit = TerminalExit::Signal("SIGKILL".to_string());
        assert_eq!(
            lifecycle.apply(SessionEventKind::Reaped(exit.clone())),
            SessionState::Exited(exit)
        );
    }

    /// 关闭后可以重开：Exited → Running 允许，且不会复活已退出的旧会话。
    #[test]
    fn session_can_be_reopened_after_exit() {
        let mut lifecycle = SessionLifecycle::new();
        lifecycle.apply(SessionEventKind::Spawned);
        lifecycle.apply(SessionEventKind::Reaped(TerminalExit::Code(1)));
        assert_eq!(
            lifecycle.apply(SessionEventKind::Spawned),
            SessionState::Running
        );
        // Running 状态下重复 Spawned 不得改变状态。
        assert_eq!(
            lifecycle.apply(SessionEventKind::Spawned),
            SessionState::Running
        );
    }

    /// 已退出的会话不再可写，Running/Stopping 会话可写。
    #[test]
    fn attached_matches_running_and_stopping() {
        assert!(SessionState::Running.is_attached());
        assert!(SessionState::Stopping.is_attached());
        assert!(!SessionState::Closed.is_attached());
        assert!(!SessionState::Exited(TerminalExit::Code(0)).is_attached());
    }

    // ---- 输入映射 ----

    /// 可打印字符原样直输；Ctrl+字母转控制字符。
    #[test]
    fn maps_printable_and_control_characters() {
        let default = TermMode::default();
        assert_eq!(
            map_key("a", Some("a"), plain(), default, 24),
            KeyAction::Send(b"a".to_vec())
        );
        assert_eq!(
            map_key("c", Some("c"), mods(true, false, false, false), default, 24),
            KeyAction::Send(vec![3])
        );
        assert_eq!(
            map_key("d", Some("d"), mods(true, false, false, false), default, 24),
            KeyAction::Send(vec![4])
        );
    }

    /// 非 macOS 平台约定：Ctrl+Shift+C/V 复制粘贴，Ctrl+V 直接粘贴。
    #[test]
    fn maps_copy_paste_and_search_shortcuts() {
        let default = TermMode::default();
        assert_eq!(
            map_key("c", None, mods(true, false, true, false), default, 24),
            KeyAction::Copy
        );
        assert_eq!(
            map_key("v", None, mods(true, false, true, false), default, 24),
            KeyAction::Paste
        );
        assert_eq!(
            map_key("v", Some("v"), mods(true, false, false, false), default, 24),
            KeyAction::Paste
        );
        assert_eq!(
            map_key("f", Some("f"), mods(true, false, false, false), default, 24),
            KeyAction::OpenSearch
        );
    }

    /// Shift+翻页滚视口，Ctrl+End 回到底部，两者都不写 PTY。
    #[test]
    fn maps_viewport_scrolling_keys() {
        let default = TermMode::default();
        assert_eq!(
            map_key("pageup", None, mods(false, false, true, false), default, 30),
            KeyAction::Scroll(30)
        );
        assert_eq!(
            map_key(
                "pagedown",
                None,
                mods(false, false, true, false),
                default,
                30
            ),
            KeyAction::Scroll(-30)
        );
        assert_eq!(
            map_key("end", None, mods(true, false, false, false), default, 30),
            KeyAction::ScrollToBottom
        );
    }

    /// 方向键按上游 `APP_CURSOR` 模式选序列。
    #[test]
    fn arrow_keys_follow_application_cursor_mode() {
        assert_eq!(
            map_key("up", None, plain(), TermMode::default(), 24),
            KeyAction::Send(b"\x1b[A".to_vec())
        );
        assert_eq!(
            map_key(
                "up",
                None,
                plain(),
                TermMode::APP_CURSOR | TermMode::default(),
                24
            ),
            KeyAction::Send(b"\x1bOA".to_vec())
        );
    }

    /// Alt+字符加 ESC 前缀，Alt+方向键是 readline 词移动。
    #[test]
    fn maps_alt_meta_sequences() {
        let default = TermMode::default();
        assert_eq!(
            map_key("b", Some("b"), mods(false, true, false, false), default, 24),
            KeyAction::Send(b"\x1bb".to_vec())
        );
        assert_eq!(
            map_key("left", None, mods(false, true, false, false), default, 24),
            KeyAction::Send(b"\x1b[b".to_vec())
        );
    }

    /// 平台键与未映射组合键放行，工作台快捷键不能被终端吞掉。
    #[test]
    fn unhandled_combinations_pass_through() {
        let default = TermMode::default();
        // Ctrl+功能键没有终端语义，归工作台。
        assert_eq!(
            map_key("home", None, mods(true, false, false, false), default, 24),
            KeyAction::Passthrough
        );
        assert_eq!(
            map_key("t", Some("t"), mods(false, false, false, true), default, 24),
            KeyAction::Passthrough
        );
        // AltGr（Ctrl+Alt）用于输入字符，不能被当成控制字符。
        assert_eq!(
            map_key("q", Some("q"), mods(true, true, false, false), default, 24),
            KeyAction::Passthrough
        );
    }

    /// Ctrl+字母仍是控制字符（readline 依赖它），不能因为“IDE 快捷键”就放行。
    #[test]
    fn control_letters_still_reach_the_shell() {
        let default = TermMode::default();
        assert_eq!(
            map_key("w", Some("w"), mods(true, false, false, false), default, 24),
            KeyAction::Send(vec![0x17])
        );
    }

    // ---- 鼠标上报 ----

    /// 上游模式未开启鼠标上报时不编码（走本地选择）。
    #[test]
    fn mouse_report_requires_upstream_mode() {
        assert!(!mouse_report_enabled(
            MouseReport::Press(0),
            TermMode::default()
        ));
        assert!(mouse_report_enabled(
            MouseReport::Press(0),
            TermMode::MOUSE_REPORT_CLICK | TermMode::default()
        ));
        assert!(!mouse_report_enabled(
            MouseReport::Drag(0),
            TermMode::MOUSE_REPORT_CLICK | TermMode::default()
        ));
        assert!(mouse_report_enabled(
            MouseReport::Drag(0),
            TermMode::MOUSE_MOTION | TermMode::default()
        ));
    }

    /// SGR 编码：行列从 1 开始，回滚偏移叠加进上报行号。
    #[test]
    fn encodes_sgr_mouse_report_with_offset() {
        assert_eq!(
            encode_mouse_report(
                MouseReport::Press(0),
                GridPoint::new(Line(-2), Column(3)),
                5,
                true
            ),
            b"\x1b[<0;4;4M".to_vec()
        );
        assert_eq!(
            encode_mouse_report(
                MouseReport::Release(0),
                GridPoint::new(Line(0), Column(0)),
                0,
                true
            ),
            b"\x1b[<3;1;1m".to_vec()
        );
        assert_eq!(
            encode_mouse_report(
                MouseReport::Drag(2),
                GridPoint::new(Line(0), Column(0)),
                0,
                true
            ),
            b"\x1b[<34;1;1M".to_vec()
        );
    }

    /// 非 SGR 模式回退 X10 编码（坐标加 32 偏移）。
    #[test]
    fn encodes_x10_mouse_report_fallback() {
        assert_eq!(
            encode_mouse_report(
                MouseReport::Press(1),
                GridPoint::new(Line(0), Column(1)),
                0,
                false
            ),
            vec![0x1b, b'[', b'M', 33, 34, 33]
        );
    }

    // ---- 搜索状态 ----

    /// 命中序号环绕：向前到末尾后回到首个，向后到首个后到末尾。
    #[test]
    fn match_index_wraps_in_both_directions() {
        assert_eq!(next_match_index(0, 3, true), 1);
        assert_eq!(next_match_index(3, 3, true), 1);
        assert_eq!(next_match_index(1, 3, false), 3);
        assert_eq!(next_match_index(0, 0, true), 0);
    }

    /// 计数文案：无命中 0/0，超出上限带 `+` 后缀。
    #[test]
    fn match_label_marks_empty_and_truncated() {
        assert_eq!(match_label(0, 0, false), "0/0");
        assert_eq!(match_label(2, 7, false), "2/7");
        assert_eq!(match_label(2, 7, true), "2/7+");
    }

    /// 查询串变化后重新收集命中，序号复位到首个命中，next 走到第二个。
    #[test]
    fn search_collects_matches_and_selects_first() {
        let term = term_with_output(b"alpha beta\r\nalpha gamma\r\n");
        let mut state = SearchState::new();
        state.set_query(&term, "alpha".to_string());
        assert_eq!(state.total(), 2);
        assert_eq!(state.current, 1);
        let first = state.current_match().expect("first match");
        assert_eq!(first.start().line.0, 0);
        assert_eq!(first.start().column.0, 0);
        state.step(true);
        let second = state.current_match().expect("second match");
        assert_eq!(second.start().line.0, 1);
        // 环绕回第一个。
        state.step(true);
        assert_eq!(state.current, 1);
    }

    /// 非法正则按无命中处理，且不保留上一次结果。
    #[test]
    fn invalid_regex_clears_previous_matches() {
        let term = term_with_output(b"alpha\r\n");
        let mut state = SearchState::new();
        state.set_query(&term, "alpha".to_string());
        assert_eq!(state.total(), 1);
        state.set_query(&term, "([".to_string());
        assert_eq!(state.total(), 0);
        assert!(state.is_empty());
    }

    /// 无命中时不产生高亮范围，计数显示 0/0。
    #[test]
    fn search_without_match_has_no_highlight() {
        let term = term_with_output(b"alpha\r\n");
        let mut state = SearchState::new();
        state.set_query(&term, "omega".to_string());
        assert_eq!(state.total(), 0);
        assert_eq!(state.current, 0);
        assert!(state.current_match().is_none());
        assert_eq!(state.label(), "0/0");
    }

    /// 引擎联通性：搜索跨回滚缓冲工作，命中集合覆盖历史行。
    #[test]
    fn search_scans_scrollback_history() {
        let mut term = Term::new(
            Config {
                scrolling_history: 100,
                ..Config::default()
            },
            &dims(20, 2),
            VoidListener,
        );
        let mut processor: Processor = Processor::new();
        processor.advance(
            &mut term,
            b"needle one\r\nneedle two\r\nneedle three\r\nneedle four",
        );
        assert!(term.grid().history_size() > 0, "history must exist");
        let mut state = SearchState::new();
        state.set_query(&term, "needle".to_string());
        assert_eq!(state.total(), 4);
        assert_eq!(state.label(), "1/4");
    }

    // ---- PTY 环境 ----

    /// 宿主终端变量被清理，能力变量被覆盖，`TMUX` 之类嵌套标识保留。
    #[test]
    fn pty_environment_clears_host_terminal_variables() {
        let mut base = BTreeMap::new();
        base.insert("PATH".to_string(), "/usr/bin".to_string());
        base.insert("TERM".to_string(), "dumb".to_string());
        base.insert("COLUMNS".to_string(), "40".to_string());
        base.insert("WT_SESSION".to_string(), "abc".to_string());
        base.insert("TMUX".to_string(), "/tmp/tmux-0/default,1,0".to_string());
        let env = pty_environment(&base);
        assert!(!env.contains_key("COLUMNS"));
        assert!(!env.contains_key("WT_SESSION"));
        assert_eq!(env.get("PATH").map(String::as_str), Some("/usr/bin"));
        assert_eq!(
            env.get("TMUX").map(String::as_str),
            Some("/tmp/tmux-0/default,1,0")
        );
        assert_eq!(env.get("TERM").map(String::as_str), Some(PTY_TERM));
        assert_eq!(
            env.get("COLORTERM").map(String::as_str),
            Some(PTY_COLORTERM)
        );
    }

    // ---- 调色板 ----

    /// 256 色：0-15 走主题 token，16 起为立方体，232 起为灰阶。
    #[test]
    fn indexed_colors_cover_base_cube_and_grayscale() {
        let palette = TermPalette::from_theme();
        let current = theme::palette();
        assert_eq!(palette.indexed(0), current.terminal_black);
        assert_eq!(palette.indexed(7), current.terminal_white);
        assert_eq!(
            palette.indexed(8),
            theme::mix(current.terminal_black, current.foreground, BRIGHT_MIX)
        );
        assert_eq!(palette.indexed(16), rgba_of((0, 0, 0)));
        assert_eq!(palette.indexed(231), rgba_of((255, 255, 255)));
        assert_eq!(palette.indexed(232), rgba_of((8, 8, 8)));
        assert_eq!(palette.indexed(255), rgba_of((238, 238, 238)));
    }

    /// 命名色不走 `as u8` 折叠：`Foreground`/`Background` 走主题，
    /// `DimRed` 走暗色变体而不是被折成 `Yellow`。
    #[test]
    fn named_colors_map_to_theme_tokens() {
        let palette = TermPalette::from_theme();
        let current = theme::palette();
        assert_eq!(palette.named(NamedColor::Foreground), current.foreground);
        assert_eq!(palette.named(NamedColor::Background), current.background);
        assert_eq!(palette.named(NamedColor::Cursor), current.foreground);
        assert_eq!(
            palette.named(NamedColor::DimRed),
            theme::mix(current.terminal_red, current.background, DIM_MIX)
        );
        assert_ne!(palette.named(NamedColor::DimRed), current.terminal_yellow);
    }

    /// 加粗时 0-7 基础色提升到 8-15 高亮 variant（标准终端行为）。
    #[test]
    fn bold_promotes_base_colors_to_bright_variants() {
        let palette = TermPalette::from_theme();
        let bold = palette.resolve(AlacColor::Named(NamedColor::Red), true);
        let normal = palette.resolve(AlacColor::Named(NamedColor::Red), false);
        assert_eq!(bold, palette.bright(1));
        assert_eq!(normal, palette.base[1]);
        assert_ne!(bold, normal);
    }

    /// `INVERSE` 交换前景底色；`HIDDEN` 让前景等于底色。
    #[test]
    fn cell_colors_handle_inverse_and_hidden() {
        let palette = TermPalette::from_theme();
        let fg = AlacColor::Indexed(1);
        let bg = AlacColor::Indexed(4);
        let (plain_fg, plain_bg) = resolve_cell_colors(fg, bg, Flags::empty(), &palette);
        let (inverse_fg, inverse_bg) = resolve_cell_colors(fg, bg, Flags::INVERSE, &palette);
        assert_eq!((inverse_fg, inverse_bg), (plain_bg, plain_fg));
        let (hidden_fg, hidden_bg) = resolve_cell_colors(fg, bg, Flags::HIDDEN, &palette);
        assert_eq!(hidden_fg, hidden_bg);
    }

    /// 光标形状按上游 `CursorShape` 映射。
    #[test]
    fn cursor_style_follows_upstream_shape() {
        assert_eq!(CursorStyle::from(CursorShape::Block), CursorStyle::Block);
        assert_eq!(
            CursorStyle::from(CursorShape::Underline),
            CursorStyle::Underline
        );
        assert_eq!(CursorStyle::from(CursorShape::Beam), CursorStyle::Beam);
        assert_eq!(
            CursorStyle::from(CursorShape::HollowBlock),
            CursorStyle::Hollow
        );
        assert_eq!(CursorStyle::from(CursorShape::Hidden), CursorStyle::Hidden);
    }

    /// 光标落在哪一格、是否补尾格、熄灭相位是否隐藏，全部由上游光标列号决定。
    #[test]
    fn cursor_placement_uses_cursor_column() {
        let cursor = CursorPlacement {
            visible: true,
            column: 3,
            style: CursorStyle::Block,
            phase: true,
        };
        assert!(cursor.covers(3));
        assert!(!cursor.covers(2));
        assert!(!cursor.trailing(4));
        assert!(cursor.trailing(2));
        let dark_phase = CursorPlacement {
            phase: false,
            ..cursor
        };
        assert!(!dark_phase.covers(3));
        assert!(!dark_phase.trailing(2));
    }

    // ---- 引擎联通性 ----

    /// 引擎联通性：喂入带 ANSI 换行的字节后，可见区出现对应文本。
    /// 这条守住 render 路径依赖的上游解析/网格行为。
    #[test]
    fn engine_parses_output_into_grid() {
        let term = term_with_output(b"hello\r\nworld");
        let content = term.renderable_content();
        let text: String = content.display_iter.map(|indexed| indexed.cell.c).collect();
        assert!(
            text.contains("hello"),
            "first line must contain hello: {text:?}"
        );
        assert!(
            text.contains("world"),
            "second line must contain world: {text:?}"
        );
    }

    /// 引擎联通性：写入超过屏高的行后可用上游 API 滚出显示偏移。
    #[test]
    fn engine_scrollback_exposes_display_offset() {
        let mut term = Term::new(
            Config {
                scrolling_history: 100,
                ..Config::default()
            },
            &dims(20, 2),
            VoidListener,
        );
        let mut processor: Processor = Processor::new();
        processor.advance(&mut term, b"one\r\ntwo\r\nthree\r\nfour");
        assert_eq!(term.grid().display_offset(), 0);
        term.scroll_display(Scroll::Delta(2));
        assert_eq!(term.grid().display_offset(), 2);
        term.scroll_display(Scroll::Bottom);
        assert_eq!(term.grid().display_offset(), 0);
    }

    /// 引擎联通性：选择一块文本后可经上游导出字符串（复制链路）。
    #[test]
    fn engine_selection_to_string_roundtrips() {
        let mut term = term_with_output(b"abcdef");
        let mut selection = Selection::new(
            SelectionType::Simple,
            GridPoint::new(Line(0), Column(0)),
            Side::Left,
        );
        selection.update(GridPoint::new(Line(0), Column(2)), Side::Right);
        term.selection = Some(selection);
        let text = term.selection_to_string().expect("selection must export");
        assert!(text.starts_with("abc"), "selection text: {text:?}");
    }

    /// 引擎联通性：resize 改变列数（随窗缩放依赖上游 reflow）。
    #[test]
    fn engine_resize_updates_columns() {
        let mut term = Term::new(Config::default(), &dims(80, 24), VoidListener);
        assert_eq!(term.columns(), 80);
        term.resize(dims(100, 30));
        assert_eq!(term.columns(), 100);
        assert_eq!(term.screen_lines(), 30);
    }

    /// 引擎联通性：宽字符在网格里占两格，第二格带占位标记，渲染必须跳过它。
    #[test]
    fn engine_marks_wide_char_spacer_cells() {
        let term = term_with_output("中".as_bytes());
        let content = term.renderable_content();
        let spacers = content
            .display_iter
            .filter(|indexed| {
                indexed
                    .cell
                    .flags
                    .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            })
            .count();
        assert_eq!(spacers, 1, "wide char must occupy a spacer cell");
    }
}
