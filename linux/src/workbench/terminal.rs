//! 原生 PTY 终端：`portable-pty` 跑 shell，`alacritty_terminal`（Alacritty
//! 网格引擎）做解析与状态，键盘字符模式直输（对齐 IDEA 内嵌终端的交互：历史、
//! 补全、方向键、中断均由 PTY 行规程处理）。
//!
//! 渲染层不自行实现终端语义，只做网格到 GPUI 元素的投影：可见区按固定字符单元格
//! 排版，同样式字符合并为一段。选择、回滚、搜索、随窗缩放全部调用
//! `alacritty_terminal` 的既有 API（`Term::scroll_display`、`Selection`、
//! `RegexSearch`、`Term::resize` 与网格 reflow），不重复实现上游能力。
//!
//! 适配声明：多标签、横向分屏、超链接点击、图形协议（Sixel/Kitty）暂不支持。//!
//! Note: 引擎复用边界与禁止手写终端语义的原因见
//! `.agents/notes/implemented/architecture/2026-09-25-linux-gpui-terminal-engine-reuse.md`。

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Direction, Line, Point as GridPoint, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::search::{Match, RegexSearch};
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color as AlacColor, CursorShape, NamedColor, Processor, Rgb};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{h_flex, v_flex, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, App, AppContext as _, Bounds, ClipboardItem, Context, FocusHandle, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, MouseButton, MouseDownEvent,
    MouseMoveEvent, MouseUpEvent, ParentElement as _, Pixels, Render, Rgba, ScrollDelta,
    ScrollWheelEvent, StatefulInteractiveElement as _, Styled as _, Window,
};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::cell::Cell;
use std::io::{Read, Write};
use std::rc::Rc;
use std::sync::{mpsc, Arc, Mutex};
use std::thread;

use crate::settings;
use crate::theme::ThemeColors;

/// 初始网格尺寸（首帧布局完成前使用，随后按容器实测尺寸 resize）。
const INITIAL_COLS: usize = 80;
const INITIAL_ROWS: usize = 24;

/// 网格最小尺寸，避免退化到 0 列触发上游断言。
const MIN_COLS: usize = 2;
const MIN_ROWS: usize = 1;

/// 平台默认 shell：Unix 用登录 shell（`$SHELL`），Windows 用 `COMSPEC`。
///
/// 两个变量都缺失时给出该平台最可能存在的回退名，避免空 program 导致 PTY 启动失败。
fn default_shell() -> String {
    #[cfg(unix)]
    {
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".to_string())
    }
    #[cfg(windows)]
    {
        std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_string())
    }
}

/// 列出在 `dir` 下应该尝试的 shell 可执行文件名。
///
/// Windows 上按 `PATHEXT` 补全（`pwsh` -> `pwsh.exe`）；名字已带扩展名或非
/// Windows 平台时只尝试原名。
fn shell_candidates(dir: &std::path::Path, name: &str) -> Vec<std::path::PathBuf> {
    #[cfg(windows)]
    {
        let mut candidates = vec![dir.join(name)];
        if std::path::Path::new(name).extension().is_none() {
            let pathext = std::env::var("PATHEXT")
                .unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
            for extension in pathext.split(';').filter(|value| !value.is_empty()) {
                candidates.push(dir.join(format!("{name}{extension}")));
            }
        }
        candidates
    }
    #[cfg(not(windows))]
    {
        vec![dir.join(name)]
    }
}

/// 行高相对字号的倍率（等宽终端常用 1.4）。
const LINE_HEIGHT_RATIO: f32 = 1.4;

/// 网格内容内边距（左上角偏移，鼠标命中换算需扣除）。
const GRID_PADDING: f32 = 4.0;

/// 网格尺寸（`Term::new` 与 `resize` 共用）。
#[derive(Debug, Clone, Copy)]
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
            // Unix 从 `$SHELL` 取用户登录 shell；Windows 没有该变量，回退到
            // `COMSPEC`（cmd.exe），这与系统终端的默认行为一致。
            default_shell()
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

    /// PTY 缩放：容器尺寸变化时调用，使 shell / 全屏 TUI 拿到最新行列数。
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

/// 单元格尺寸（像素），渲染与鼠标命中都用它换算行列。
#[derive(Debug, Clone, Copy)]
struct CellMetrics {
    width: f32,
    height: f32,
}

/// 终端内搜索状态：查询串、上游正则缓存与命中计数。
struct SearchState {
    query: String,
    regex: Option<RegexSearch>,
    /// 当前命中序号（1 起，0 表示无命中）。
    current: usize,
    /// 命中总数；上游按需搜索，不预先全量统计，未统计时为 0。
    total: usize,
}

impl SearchState {
    fn new() -> Self {
        Self {
            query: String::new(),
            regex: None,
            current: 0,
            total: 0,
        }
    }

    fn clear(&mut self) {
        self.query.clear();
        self.regex = None;
        self.current = 0;
        self.total = 0;
    }
}

/// 终端视图组件：点击聚焦后键盘字符模式直输（IDEA 式交互）。
///
/// 网格引擎与交互能力全部来自上游 `alacritty_terminal`：本结构只负责调用
/// 它的 resize/scroll/selection/search API，并把结果投影成 GPUI 元素。
pub struct TerminalView {
    pub session: Option<TerminalSession>,
    pub working_dir: String,
    term: Term<VoidListener>,
    processor: Processor,
    focus_handle: FocusHandle,
    /// 最近一次已知的网格尺寸（行列），用于判断是否需要 resize。
    size: TermDims,
    /// 单元格像素尺寸；每次 render 按当前字号实测写入。
    cell: CellMetrics,
    /// 网格内容区边界（窗口坐标）；由 `on_children_prepainted` 写入。
    grid_bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    /// 正在拖拽选择时的选区类型。
    dragging: Option<SelectionType>,
    /// 终端内搜索状态。
    search: SearchState,
    /// 搜索栏输入框实体（懒创建）。
    search_input: Option<gpui_kit::Entity<InputState>>,
    /// 搜索输入框 Change 订阅。
    search_subscription: Option<gpui_kit::Subscription>,
    /// 请求在下一帧展开搜索栏（键盘事件没有 `Window`，输入框需在 render 创建）。
    search_requested: bool,
}

impl TerminalView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let scrollback = settings::get(cx).terminal_scrollback.max(1);
        let mut view = Self {
            session: None,
            working_dir,
            term: Term::new(
                Config {
                    scrolling_history: scrollback,
                    ..Config::default()
                },
                &TermDims {
                    cols: INITIAL_COLS,
                    rows: INITIAL_ROWS,
                },
                VoidListener,
            ),
            processor: Processor::new(),
            focus_handle: cx.focus_handle(),
            size: TermDims {
                cols: INITIAL_COLS,
                rows: INITIAL_ROWS,
            },
            cell: CellMetrics {
                width: 8.0,
                height: 18.0,
            },
            grid_bounds: Rc::new(Cell::new(None)),
            dragging: None,
            search: SearchState::new(),
            search_input: None,
            search_subscription: None,
            search_requested: false,
        };
        view.attach_session(cx);
        view
    }

    /// 打开 PTY 会话并起主线程输出泵（channel 收字节块 → 网格解析 → notify）。
    fn attach_session(&mut self, cx: &mut Context<Self>) {
        let shell = Self::resolve_shell(cx);
        match TerminalSession::new(
            self.size.cols as u16,
            self.size.rows as u16,
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
    /// `PATH` 解析为路径），为空回退平台默认 shell。
    fn resolve_shell(cx: &App) -> String {
        let id = settings::get(cx)
            .terminal_default_shell_id
            .trim()
            .to_string();
        if id.is_empty() {
            return String::new();
        }
        // 已含路径分隔符（`/` 或 `\`）时视为绝对/相对路径，直接使用。
        if id.contains('/') || id.contains('\\') {
            return id;
        }
        if let Some(paths) = std::env::var_os("PATH") {
            for dir in std::env::split_paths(&paths) {
                for candidate in shell_candidates(&dir, &id) {
                    if candidate.is_file() {
                        return candidate.to_string_lossy().to_string();
                    }
                }
            }
        }
        // 某些发行版的 shell 不在 PATH 中，退回固定系统目录。
        #[cfg(unix)]
        {
            let fallback = format!("/bin/{id}");
            if std::path::Path::new(&fallback).is_file() {
                return fallback;
            }
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
        self.attach_session(cx);
    }

    /// 依据容器实测尺寸同步网格与 PTY（上游 reflow 由 `Term::resize` 完成）。
    fn sync_size(&mut self, bounds: Bounds<Pixels>, cx: &mut Context<Self>) {
        let width = f32::from(bounds.size.width) - GRID_PADDING * 2.0;
        let height = f32::from(bounds.size.height) - GRID_PADDING * 2.0;
        if width <= 0.0 || height <= 0.0 {
            return;
        }

        let cols = ((width / self.cell.width).floor() as usize).max(MIN_COLS);
        let rows = ((height / self.cell.height).floor() as usize).max(MIN_ROWS);
        if cols == self.size.cols && rows == self.size.rows {
            return;
        }

        self.size = TermDims { cols, rows };
        self.term.resize(self.size);
        if let Some(session) = &self.session {
            session.resize(cols as u16, rows as u16);
        }
        cx.notify();
    }

    /// 窗口坐标 → 网格点（含回滚偏移）；越界返回 `None`。
    fn grid_point_at(&self, position: gpui_kit::Point<Pixels>) -> Option<GridPoint> {
        let bounds = self.grid_bounds.get()?;
        let display_offset = self.term.grid().display_offset();
        viewport_to_grid_point(
            f32::from(position.x) - f32::from(bounds.origin.x),
            f32::from(position.y) - f32::from(bounds.origin.y),
            self.cell,
            self.size,
            display_offset,
        )
    }

    /// 开始一次选择（单击 simple / 双击 semantic / 三击 lines）。
    fn begin_selection(&mut self, point: GridPoint, ty: SelectionType) {
        self.term.selection = Some(Selection::new(ty, point, Side::Left));
    }

    /// 更新拖拽中的选择终点。
    fn update_selection(&mut self, point: GridPoint) {
        if let Some(selection) = self.term.selection.as_mut() {
            selection.update(point, Side::Right);
        }
    }

    /// 复制当前选择到系统剪贴板；无选择返回 false。
    fn copy_selection(&mut self, cx: &mut App) -> bool {
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
        if let Some(session) = &self.session {
            let _ = session.write_bytes(text.as_bytes());
        }
    }

    /// 搜索串变化：重建上游正则并跳到首个命中。
    fn set_search_query(&mut self, query: String, cx: &mut Context<Self>) {
        self.search.query = query;
        self.search.current = 0;
        self.search.total = 0;
        self.search.regex = if self.search.query.is_empty() {
            None
        } else {
            RegexSearch::new(&self.search.query).ok()
        };
        self.search_step(true, cx);
    }

    /// 跳到下一个/上一个命中。`forward` 决定方向。
    fn search_step(&mut self, forward: bool, cx: &mut Context<Self>) {
        let Some(regex) = self.search.regex.as_mut() else {
            cx.notify();
            return;
        };
        if self.search.query.is_empty() {
            cx.notify();
            return;
        }

        let direction = if forward {
            Direction::Right
        } else {
            Direction::Left
        };
        let origin = self.term.grid().cursor.point;
        let found: Option<Match> =
            self.term
                .search_next(regex, origin, direction, Side::Left, None);

        if let Some(found) = found {
            self.search.current = if forward {
                self.search.current.saturating_add(1).max(1)
            } else {
                self.search.current.saturating_sub(1).max(1)
            };
            // 把命中滚入视口并选中，复用上游 selection 作为高亮来源。
            let start = *found.start();
            let end = *found.end();
            self.term.scroll_to_point(start);
            let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
            selection.update(end, Side::Right);
            self.term.selection = Some(selection);
        } else {
            self.search.current = 0;
        }
        cx.notify();
    }

    /// 关闭搜索栏并清除搜索态选择。
    fn close_search(&mut self, cx: &mut Context<Self>) {
        self.search.clear();
        self.term.selection = None;
        self.search_requested = false;
        // 丢弃输入框实体即释放搜索栏；下次打开重建空值输入框。
        self.search_subscription = None;
        self.search_input = None;
        cx.notify();
    }

    /// 搜索栏是否可见。
    fn search_visible(&self) -> bool {
        self.search_requested || self.search_input.is_some()
    }

    /// 懒创建搜索输入框并订阅 Change 事件，值同步到搜索状态。
    fn ensure_search_input(
        slot: &mut Option<gpui_kit::Entity<InputState>>,
        subscription: &mut Option<gpui_kit::Subscription>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Entity<InputState> {
        if let Some(entity) = slot {
            return entity.clone();
        }
        let entity = cx.new(|cx| InputState::new(window, cx));
        let value_source = entity.clone();
        *subscription = Some(cx.subscribe(
            &entity,
            move |this: &mut Self, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    let value = value_source.read(cx).value().to_string();
                    this.set_search_query(value, cx);
                }
            },
        ));
        *slot = Some(entity.clone());
        entity
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
    fn handle_key(&mut self, event: &KeyDownEvent, cx: &mut App) -> bool {
        let key = event.keystroke.key.as_str();
        let mods = &event.keystroke.modifiers;

        // 终端内复制/粘贴/搜索：Ctrl+Shift+C / Ctrl+Shift+V / Ctrl+Shift+F。
        // 放在最前，避免被下面的 Ctrl 控制字符分支吞掉。
        if mods.control && mods.shift && !mods.alt && !mods.platform {
            match key.to_lowercase().as_str() {
                "c" => {
                    self.copy_selection(cx);
                    return true;
                }
                "v" => {
                    self.paste_clipboard(cx);
                    return true;
                }
                "f" => {
                    // 输入框需要 `Window`，此处只登记请求，render 阶段创建。
                    // 刷新由调用方 `on_key_down` 统一触发。
                    self.search_requested = true;
                    return true;
                }
                _ => {}
            }
        }

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

        // 单元格基准宽度：等宽字体下用上游 `em_layout_width` 实测（随字号变化）。
        let font_size = px(crate::settings::get(cx).terminal_font_size);
        let font = gpui_kit::Font {
            family: "monospace".into(),
            ..Default::default()
        };
        let font_id = window.text_system().resolve_font(&font);
        let cell_width =
            f32::from(window.text_system().em_layout_width(font_id, font_size)).max(1.0);
        let line_height = f32::from(font_size) * LINE_HEIGHT_RATIO;
        self.cell = CellMetrics {
            width: cell_width,
            height: line_height,
        };

        // 用上一帧 prepaint 记录的容器边界同步网格与 PTY；尺寸变化时
        // `sync_size` 内部 resize 上游网格并通知 PTY。
        if let Some(bounds) = self.grid_bounds.get() {
            self.sync_size(bounds, cx);
        }

        // 可见区按行分组（`display_iter` 即当前视口，已含回滚偏移）。
        let content = self.term.renderable_content();
        let selection = content.selection;
        let default_fg = ThemeColors::foreground();
        let default_bg = ThemeColors::background();
        let selection_color = ThemeColors::accent();

        let mut rows: Vec<(i32, Vec<TermCell>)> = Vec::new();
        for indexed in content.display_iter {
            let line = indexed.point.line.0;
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
            let selected = selection
                .as_ref()
                .is_some_and(|range| range.contains(indexed.point));
            rows.last_mut()
                .expect("rows non-empty after push")
                .1
                .push(TermCell {
                    c: cell.c,
                    fg,
                    bg,
                    bold,
                    selected,
                });
        }
        let (cursor_line, cursor_col, cursor_visible) = (
            content.cursor.point.line.0,
            content.cursor.point.column.0,
            focused
                && !matches!(content.cursor.shape, CursorShape::Hidden)
                && self.term.grid().display_offset() == 0,
        );

        let grid = div()
            .flex_1()
            .w_full()
            .min_h_0()
            .overflow_hidden()
            .pt(px(GRID_PADDING))
            .pl(px(GRID_PADDING))
            .text_size(font_size)
            .font_family("monospace")
            .children(rows.into_iter().map(|(line, cells)| {
                render_term_row(
                    line,
                    &cells,
                    cursor_visible && line == cursor_line,
                    cursor_col,
                    default_fg,
                    default_bg,
                    selection_color,
                    cell_width,
                    line_height,
                )
            }));

        // 搜索输入框懒创建 + 一次性订阅 Change（键盘请求在 render 落地）。
        let search_input = self.search_visible().then(|| {
            Self::ensure_search_input(
                &mut self.search_input,
                &mut self.search_subscription,
                window,
                cx,
            )
        });

        // prepaint 记录网格容器边界，供鼠标坐标换算与 resize。
        // `on_children_prepainted` 给出的是子元素边界，因此外层包一层只有一个
        // 子元素的容器，`bounds.first()` 就是网格容器自身的实测边界。
        let bounds_slot = self.grid_bounds.clone();
        let grid_with_bounds = div()
            .flex_1()
            .w_full()
            .min_h_0()
            .on_children_prepainted(move |bounds, _window, _cx| {
                if let Some(first) = bounds.first() {
                    bounds_slot.set(Some(*first));
                }
            })
            .child(grid);

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
                if this.handle_key(event, cx) {
                    cx.stop_propagation();
                    cx.notify();
                }
            }))
            // 鼠标：按下定位并记录选区起点，拖动更新，抬起结束。
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, _window, cx| {
                    let Some(point) = this.grid_point_at(event.position) else {
                        return;
                    };
                    let ty = match event.click_count {
                        0 | 1 => SelectionType::Simple,
                        2 => SelectionType::Semantic,
                        _ => SelectionType::Lines,
                    };
                    this.begin_selection(point, ty);
                    this.dragging = Some(ty);
                    cx.notify();
                }),
            )
            .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _window, cx| {
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
                cx.listener(|this, _event: &MouseUpEvent, _window, cx| {
                    this.dragging = None;
                    cx.notify();
                }),
            )
            // 滚轮：直接驱动上游滚动缓冲。
            .on_scroll_wheel(cx.listener(|this, event: &ScrollWheelEvent, _window, cx| {
                let lines = match event.delta {
                    ScrollDelta::Lines(point) => f64::from(point.y),
                    ScrollDelta::Pixels(point) => f64::from(point.y) / this.cell.height as f64,
                };
                let delta = lines.round() as i32;
                if delta != 0 {
                    this.term.scroll_display(Scroll::Delta(delta));
                    cx.notify();
                }
            }))
            .when_some(search_input, |el, input| {
                el.child(self.render_search_bar(input, cx))
            })
            .child(grid_with_bounds)
    }
}

impl TerminalView {
    /// 渲染搜索栏（终端内搜索，对齐 Tauri 终端搜索条）。
    fn render_search_bar(
        &self,
        input: gpui_kit::Entity<InputState>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let counter = if self.search.query.is_empty() {
            String::new()
        } else {
            format!(
                "{}/{}",
                self.search.current,
                self.search.total.max(self.search.current)
            )
        };
        h_flex()
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap_2()
            .px_2()
            .py_1()
            .bg(ThemeColors::bg_tab_bar())
            .border_b_1()
            .border_color(ThemeColors::border())
            .child(
                div()
                    .flex_1()
                    .child(Input::new(&input).small().cleanable(true)),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child(counter),
            )
            .child(
                Button::new("terminal-search-prev")
                    .small()
                    .ghost()
                    .icon(gpui_kit::assets::IconName::ChevronUp)
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.search_step(false, cx);
                    })),
            )
            .child(
                Button::new("terminal-search-next")
                    .small()
                    .ghost()
                    .icon(gpui_kit::assets::IconName::ChevronDown)
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.search_step(true, cx);
                    })),
            )
            .child(
                Button::new("terminal-search-close")
                    .small()
                    .ghost()
                    .icon(gpui_kit::assets::IconName::X)
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.close_search(cx);
                    })),
            )
    }
}

/// 一个网格单元格的渲染数据（有序遍历 `display_iter` 时收集）。
#[derive(Clone, Copy)]
struct TermCell {
    c: char,
    fg: AlacColor,
    bg: AlacColor,
    bold: bool,
    selected: bool,
}

/// 渲染网格一行：同样式字符合并为一段；选中字符用选区底色；聚焦时在光标处
/// 画反色块。每段用固定像素宽度（`字符数 × cell_width`）保证等宽对齐，
/// 鼠标命中换算依赖同一套单元格尺寸。
#[allow(clippy::too_many_arguments)]
fn render_term_row(
    line: i32,
    cells: &[TermCell],
    cursor_here: bool,
    cursor_col: usize,
    default_fg: Rgba,
    default_bg: Rgba,
    selection_color: Rgba,
    cell_width: f32,
    line_height: f32,
) -> gpui_kit::AnyElement {
    let mut row = h_flex()
        .id(format!("term-row-{line}"))
        .w_full()
        .h(px(line_height))
        .items_center()
        .font_family("monospace");
    if cells.is_empty() {
        // 空行：只有光标落在首格时画块，否则保底一个空格占位。
        if cursor_here && cursor_col == 0 {
            row = row.child(
                div()
                    .flex_shrink_0()
                    .w(px(cell_width))
                    .text_color(default_bg)
                    .bg(default_fg)
                    .child(" ".to_string()),
            );
        } else {
            row = row.child(div().child(" "));
        }
        return row.into_any_element();
    }

    // 逐格构建：同样式连续字符合并成段，光标位单独成块。
    let mut index = 0usize;
    while index < cells.len() {
        let cell = cells[index];
        let is_cursor = cursor_here && index == cursor_col;

        if is_cursor {
            // 光标块：反色（前景当底、背景当字），宽一格。
            row = row.child(
                div()
                    .flex_shrink_0()
                    .w(px(cell_width))
                    .text_color(default_bg)
                    .bg(resolve_color(cell.fg, cell.bold, default_fg))
                    .child(cell.c.to_string()),
            );
            index += 1;
            continue;
        }

        // 合并同 (fg,bg,bold,selected) 的后续字符。
        let mut text = String::new();
        text.push(cell.c);
        let mut len = 1usize;
        while index + len < cells.len() {
            let next = cells[index + len];
            if cursor_here && index + len == cursor_col {
                break;
            }
            if next.fg != cell.fg
                || next.bg != cell.bg
                || next.bold != cell.bold
                || next.selected != cell.selected
            {
                break;
            }
            text.push(next.c);
            len += 1;
        }

        let fg = resolve_color(cell.fg, cell.bold, default_fg);
        let bg = resolve_color(cell.bg, false, default_bg);
        row = row.child(
            div()
                .flex_shrink_0()
                .w(px(cell_width * len as f32))
                .text_color(fg)
                .when(cell.selected, |el| el.bg(selection_color))
                .when(
                    !cell.selected && cell.bg != AlacColor::Named(NamedColor::Background),
                    |el| el.bg(bg),
                )
                .when(cell.bold, |el| el.font_weight(FontWeight::BOLD))
                .child(text),
        );
        index += len;
    }

    // 光标超出已给出单元格（行尾之后）：补一个反色空格块。
    if cursor_here && cursor_col >= cells.len() {
        row = row.child(
            div()
                .flex_shrink_0()
                .w(px(cell_width))
                .text_color(default_bg)
                .bg(default_fg)
                .child(" ".to_string()),
        );
    }

    row.into_any_element()
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

    /// 256 色查表：0-15 取基础色，16 起为立方体，232 起为灰阶。
    #[test]
    fn palette_256_covers_base_cube_and_grayscale() {
        assert_eq!(palette_256(0), ANSI_PALETTE[0]);
        assert_eq!(palette_256(15), ANSI_PALETTE[15]);
        assert_eq!(palette_256(16), (0, 0, 0));
        assert_eq!(palette_256(231), (255, 255, 255));
        assert_eq!(palette_256(232), (8, 8, 8));
        assert_eq!(palette_256(255), (238, 238, 238));
    }

    /// 加粗时 0-7 基础色提升到 8-15 高亮 variant（标准终端行为）。
    #[test]
    fn bold_promotes_base_colors_to_bright_variants() {
        let bold = resolve_color(AlacColor::Named(NamedColor::Red), true, Rgba::default());
        let normal = resolve_color(AlacColor::Named(NamedColor::Red), false, Rgba::default());
        assert_eq!(bold, rgba_of(ANSI_PALETTE[9]));
        assert_eq!(normal, rgba_of(ANSI_PALETTE[1]));
        assert_ne!(bold, normal);
    }

    /// 引擎联通性：喂入带 ANSI 换行的字节后，可见区出现对应文本。
    /// 这条守住 render 路径依赖的上游解析/网格行为。
    #[test]
    fn engine_parses_output_into_grid() {
        let mut term = Term::new(Config::default(), &dims(20, 4), VoidListener);
        let mut processor: Processor = Processor::new();
        processor.advance(&mut term, b"hello\r\nworld");
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
        let mut term = Term::new(Config::default(), &dims(20, 4), VoidListener);
        let mut processor: Processor = Processor::new();
        processor.advance(&mut term, b"abcdef");
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
        use alacritty_terminal::grid::Dimensions as _;
        let mut term = Term::new(Config::default(), &dims(80, 24), VoidListener);
        assert_eq!(term.columns(), 80);
        term.resize(dims(100, 30));
        assert_eq!(term.columns(), 100);
        assert_eq!(term.screen_lines(), 30);
    }

    /// 默认前景/背景取主题色；加粗不改变已高于 7 的索引颜色。
    #[test]
    fn default_colors_follow_theme_and_bold_ignored_above_index_seven() {
        let theme = Rgba {
            r: 0.25,
            g: 0.5,
            b: 0.75,
            a: 1.0,
        };
        assert_eq!(
            resolve_color(AlacColor::Named(NamedColor::Foreground), false, theme),
            theme
        );
        assert_eq!(
            resolve_color(AlacColor::Named(NamedColor::Background), true, theme),
            theme
        );
        assert_eq!(
            resolve_color(AlacColor::Indexed(9), true, theme),
            rgba_of(ANSI_PALETTE[9])
        );
    }
}
