//! Linux 内嵌终端：终端引擎、渲染、键鼠输入、选择与剪贴板全部复用 vendored
//! `gpui_xterm`（上游 Modolet/gpui_xterm，见 `third_party/gpui_xterm/`）。
//!
//! 本文件只保留 Lithe 拥有的三层职责，不再手写 ANSI 解析、网格、光标或键位映射：
//!
//! 1. **会话编排**（[`TerminalSession`]）：打开/关闭 PTY，回收子进程与等待线程，
//!    上报退出码与信号；终止路径复用 `run::process` 的进程组契约。
//! 2. **工程接线**：把工作目录、平台 shell、字体/回滚设置与主题色映射成
//!    `gpui_xterm::TerminalConfig`，把组件上报的行列数同步给 PTY。
//! 3. **宿主能力**：在组件之上补它未提供的产品能力——终端内搜索浮层、程序化
//!    发送命令、清屏、回到底部与退出状态展示。
//!
//! 适配声明：组件本身不提供搜索、程序化写入与显示偏移查询，因此 vendored 副本
//! 暴露了 `TerminalView::state()`（见 `third_party/gpui_xterm/README.md` 的本地
//! 补丁清单）。除此之外不扩展组件的渲染与输入职责。
//!
//! Note: 组件复用边界、被否方案与依赖适配原因见
//! `.agents/notes/implemented/architecture/2026-09-26-linux-gpui-terminal-component-reuse.md`。

use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use alacritty_terminal::event::EventListener;
use alacritty_terminal::grid::Dimensions as _;
use alacritty_terminal::index::{Column, Direction, Line, Point as GridPoint, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::term::search::{Match, RegexSearch};
use alacritty_terminal::term::Term;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, App, AppContext as _, ClipboardItem, Context, Edges, Entity,
    InteractiveElement as _, IntoElement, KeyDownEvent, MouseButton, ParentElement as _, Render,
    Rgba, Styled as _, Subscription, Window,
};
use gpui_xterm::{ColorPalette, TerminalConfig, TerminalView as XtermView};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};

use crate::settings;
use crate::theme::{self, ThemeColors};
use crate::workbench::run::process::terminate_process_group;
use crate::workbench::search_input::SearchInput;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 引导网格尺寸：只用于 PTY 首次打开与组件初始网格。组件首次测量到容器尺寸后
/// 会经 resize 回调把真实行列数报给 PTY，不会停留在该值。
const BOOTSTRAP_COLS: usize = 80;
const BOOTSTRAP_ROWS: usize = 24;

/// PTY 行列数边界，避免退化到 0 或上报荒谬尺寸。
const MIN_COLS: usize = 2;
const MIN_ROWS: usize = 1;
const MAX_COLS: usize = 1000;
const MAX_ROWS: usize = 1000;

/// 网格内容内边距（与旧实现的 4px 视觉密度保持一致）。
const GRID_PADDING: f32 = 4.0;

/// 关闭会话时先温和终止的等待时长；超时升级为强杀。与 `run::process` 的停止
/// 契约一致：宁可多等，也不给用户留下孤儿 shell。
const SESSION_STOP_GRACE: Duration = Duration::from_secs(2);

/// 强杀后的兜底等待时长；仍不退出即放弃等待（子进程已收到 KILL，由内核回收）。
const SESSION_KILL_GRACE: Duration = Duration::from_millis(500);

/// 搜索命中的计数上限：回滚缓冲可能有十万行，正则全量扫描必须有界。
/// 超出后计数带 `+`，导航仍然正确（只截断总数展示）。
const SEARCH_MATCH_CAP: usize = 512;

/// 亮色变体向前景色混合的比例（ANSI 8-15 = 基础色 + 前景色）。
const BRIGHT_MIX: f32 = 0.55;

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
    /// 展示用明细：供宿主状态区展示。
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
    /// 还没有 PTY 会话（面板刚建、创建失败，或用户显式关闭了会话）。
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
fn default_shell() -> String {
    if cfg!(unix) {
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
    } else {
        std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_string())
    }
}

/// 列出在 `dir` 下应该尝试的 shell 可执行文件名。
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
// 搜索（Lithe 补能力，正则与命中语义来自上游 alacritty 引擎）
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
fn next_search_origin<T: EventListener>(term: &Term<T>, found: &Match) -> Option<GridPoint> {
    let end = *found.end();
    if end.column < term.last_column() {
        return Some(GridPoint::new(end.line, Column(end.column.0 + 1)));
    }
    if end.line.0 + 1 < term.total_lines() as i32 {
        return Some(GridPoint::new(Line(end.line.0 + 1), Column(0)));
    }
    None
}

/// 从网格最旧一行开始收集全部命中，直到没有更多或达到上限。
///
/// 上游 `search_next` 在“起点之后没有命中”时会回退返回第一个命中，因此必须
/// 自己判断是否已经环绕：命中起点不再前进即视为收集结束。
fn collect_matches<T: EventListener>(
    term: &Term<T>,
    regex: &mut RegexSearch,
    cap: usize,
) -> (Vec<Match>, bool) {
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
            None => break,
        }
    }
    let truncated = matches.len() >= cap;
    (matches, truncated)
}

/// 终端内搜索状态：查询串、有界的命中列表与当前序号。命中集合是最新一次
/// 扫描的快照，输出变化后由宿主重新扫描。
struct SearchState {
    query: String,
    matches: Vec<Match>,
    /// 当前命中序号（1 起，0 表示无命中）。
    current: usize,
    /// 命中数是否被上限截断。
    truncated: bool,
}

impl SearchState {
    fn new() -> Self {
        Self {
            query: String::new(),
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

    fn clear(&mut self) {
        self.query.clear();
        self.matches.clear();
        self.current = 0;
        self.truncated = false;
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
}

// ---------------------------------------------------------------------------
// 会话层
// ---------------------------------------------------------------------------

/// 会话事件：子进程已被回收，宿主应重绘以展示退出状态。退出码/信号本身由
/// 会话层的生命周期状态持有，事件只承担“状态已变化”的通知职责。
#[derive(Debug)]
pub enum SessionEvent {
    /// 子进程已回收。
    Closed,
}

/// 会话内部状态。会话句柄与停机看门狗共享它，因此全部可跨线程。
struct SessionInner {
    /// 共享写端：会话与 `gpui_xterm` 组件各持一个句柄，共同写入同一 PTY。
    writer: Arc<Mutex<Option<Box<dyn Write + Send>>>>,
    /// 主端句柄：停机时释放以让 slave 收到 hangup，运行期用于 resize。
    master: Mutex<Option<Box<dyn MasterPty + Send>>>,
    /// 只用于停机兜底的信号句柄。
    killer: Mutex<Option<Box<dyn ChildKiller + Send + Sync>>>,
    /// 子进程等待线程：由停机看门狗负责 join。
    monitor: Mutex<Option<JoinHandle<()>>>,
    /// 前台进程组 id（`portable-pty` 让子进程 `setsid`，因此它就是组长）。
    pgid: Option<i32>,
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
    /// 阻塞在 `read` 的组件读取线程也会返回。
    fn release_master(&self) {
        if let Ok(mut guard) = self.master.lock() {
            guard.take();
        }
    }

    /// 把组件上报的行列数同步给 PTY。
    fn resize(&self, cols: usize, rows: usize) {
        if let Ok(guard) = self.master.lock() {
            if let Some(master) = guard.as_ref() {
                let _ = master.resize(pty_size(cols, rows));
            }
        }
    }
}

/// 共享写端：`gpui_xterm` 组件需要拿走一个 `Write` 句柄，宿主又需要保留
/// 程序化写入（`send_command`）的能力，因此双方共享同一份底层 writer。
#[derive(Clone)]
pub struct SharedWriter(Arc<Mutex<Option<Box<dyn Write + Send>>>>);

impl Write for SharedWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let mut guard = self
            .0
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "terminal writer poisoned"))?;
        match guard.as_mut() {
            Some(writer) => writer.write(buf),
            None => Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "terminal writer closed",
            )),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        let mut guard = self
            .0
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "terminal writer poisoned"))?;
        match guard.as_mut() {
            Some(writer) => writer.flush(),
            None => Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "terminal writer closed",
            )),
        }
    }
}

/// Linux 原生 PTY 会话：拥有主端句柄、共享写端与子进程等待线程。
///
/// 生命周期契约与 `run::process` 的受管进程一致：先温和终止、超过
/// [`SESSION_STOP_GRACE`] 升级为强杀，最后 join 等待线程。只 `drop` 主端句柄
/// 是不够的——那样拿不到退出码，也可能在子孙进程上留下残留。
pub struct TerminalSession {
    inner: Arc<SessionInner>,
    /// 展示用 shell 路径。
    shell: String,
}

impl TerminalSession {
    /// 打开 PTY 会话并起等待线程。返回会话、供组件读取的输出端与事件接收端。
    ///
    /// 输出端交给 `gpui_xterm` 的读取线程；本会话只负责子进程生命周期。
    pub fn new(
        working_dir: &str,
        shell: &str,
    ) -> anyhow::Result<(Self, Box<dyn Read + Send>, mpsc::Receiver<SessionEvent>)> {
        let pty_system = native_pty_system();
        let pair = pty_system.openpty(pty_size(BOOTSTRAP_COLS, BOOTSTRAP_ROWS))?;

        let mut cmd = CommandBuilder::new(shell);
        if !working_dir.trim().is_empty() {
            cmd.cwd(working_dir);
        }
        for (key, value) in pty_environment(&std::env::vars().collect()) {
            cmd.env(key, value);
        }

        let mut child = pair.slave.spawn_command(cmd)?;
        let killer = child.clone_killer();
        let pgid = process_group_id(&pair.master, &child);
        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        // slave 由父进程持有会让 PTY 永远看不到 hangup，spawn 后立刻释放。
        drop(pair.slave);

        let inner = Arc::new(SessionInner {
            writer: Arc::new(Mutex::new(Some(writer))),
            master: Mutex::new(Some(pair.master)),
            killer: Mutex::new(Some(killer)),
            monitor: Mutex::new(None),
            pgid,
            stop_requested: AtomicBool::new(false),
            lifecycle: Mutex::new(SessionLifecycle::new()),
            finished: Mutex::new(false),
            finished_signal: Condvar::new(),
        });
        if let Ok(mut lifecycle) = inner.lifecycle.lock() {
            lifecycle.apply(SessionEventKind::Spawned);
        }

        let (tx, rx) = mpsc::channel::<SessionEvent>();
        let monitor = {
            let inner = inner.clone();
            thread::Builder::new()
                .name("lithe-terminal-wait".to_string())
                .spawn(move || {
                    let exit = match child.wait() {
                        Ok(status) => exit_of(status),
                        Err(_) => TerminalExit::Unknown,
                    };
                    if let Ok(mut lifecycle) = inner.lifecycle.lock() {
                        lifecycle.apply(SessionEventKind::Reaped(exit));
                    }
                    inner.mark_finished();
                    let _ = tx.send(SessionEvent::Closed);
                })
                .map_err(|error| anyhow::anyhow!("Could not start PTY waiter: {error}"))?
        };
        if let Ok(mut slot) = inner.monitor.lock() {
            *slot = Some(monitor);
        }

        Ok((
            Self {
                inner,
                shell: shell.to_string(),
            },
            reader,
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

    /// 供组件持有的共享写端；宿主也用它在程序化发送命令时写入同一 PTY。
    pub fn writer(&self) -> SharedWriter {
        SharedWriter(self.inner.writer.clone())
    }

    /// 供组件注册的 resize 回调：组件测出真实行列数后同步 PTY。
    pub fn resize_callback(&self) -> Box<dyn Fn(usize, usize) + Send + Sync> {
        let inner = self.inner.clone();
        Box::new(move |cols, rows| inner.resize(cols, rows))
    }

    /// 写入终端输入（程序化发送命令共用这一条路径）。
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
                if let Ok(mut slot) = inner.monitor.lock() {
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
            if let Ok(mut slot) = self.inner.monitor.lock() {
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

fn pty_size(cols: usize, rows: usize) -> PtySize {
    PtySize {
        rows: rows.clamp(MIN_ROWS, MAX_ROWS) as u16,
        cols: cols.clamp(MIN_COLS, MAX_COLS) as u16,
        pixel_width: 0,
        pixel_height: 0,
    }
}

/// 取子进程进程组 id：优先用主端报告的前台进程组（`portable-pty` 让子进程
/// `setsid`，因此它就是组长），其次退回子进程 pid。
fn process_group_id(
    master: &Box<dyn MasterPty + Send>,
    child: &Box<dyn portable_pty::Child + Send + Sync>,
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

fn exit_of(status: portable_pty::ExitStatus) -> TerminalExit {
    match status.signal() {
        Some(signal) if !signal.is_empty() => TerminalExit::Signal(signal.to_string()),
        _ => TerminalExit::Code(status.exit_code() as i32),
    }
}

// ---------------------------------------------------------------------------
// 主题映射
// ---------------------------------------------------------------------------

/// Rgba（0..1 浮点）→ 8 位 RGB，供 `ColorPaletteBuilder` 使用。
fn rgb8(color: Rgba) -> (u8, u8, u8) {
    (
        (color.r.clamp(0.0, 1.0) * 255.0).round() as u8,
        (color.g.clamp(0.0, 1.0) * 255.0).round() as u8,
        (color.b.clamp(0.0, 1.0) * 255.0).round() as u8,
    )
}

/// 由工作台主题派生终端调色板：8 个基础色取 `terminal_*` token，亮色变体向前景
/// 混合，前景/背景/光标取主题对应色。仓库里不再保留第二份硬编码 ANSI 调色板。
///
/// 集成终端与 Run/Maven 输出控制台共用这一份，避免两套配色漂移。
pub(crate) fn terminal_color_palette() -> ColorPalette {
    let p = theme::palette();
    let bright = |base: Rgba| rgb8(theme::mix(base, p.foreground, BRIGHT_MIX));
    ColorPalette::builder()
        .background(
            rgb8(p.background).0,
            rgb8(p.background).1,
            rgb8(p.background).2,
        )
        .foreground(
            rgb8(p.foreground).0,
            rgb8(p.foreground).1,
            rgb8(p.foreground).2,
        )
        .cursor(
            rgb8(p.foreground).0,
            rgb8(p.foreground).1,
            rgb8(p.foreground).2,
        )
        .black(
            rgb8(p.terminal_black).0,
            rgb8(p.terminal_black).1,
            rgb8(p.terminal_black).2,
        )
        .red(
            rgb8(p.terminal_red).0,
            rgb8(p.terminal_red).1,
            rgb8(p.terminal_red).2,
        )
        .green(
            rgb8(p.terminal_green).0,
            rgb8(p.terminal_green).1,
            rgb8(p.terminal_green).2,
        )
        .yellow(
            rgb8(p.terminal_yellow).0,
            rgb8(p.terminal_yellow).1,
            rgb8(p.terminal_yellow).2,
        )
        .blue(
            rgb8(p.terminal_blue).0,
            rgb8(p.terminal_blue).1,
            rgb8(p.terminal_blue).2,
        )
        .magenta(
            rgb8(p.terminal_magenta).0,
            rgb8(p.terminal_magenta).1,
            rgb8(p.terminal_magenta).2,
        )
        .cyan(
            rgb8(p.terminal_cyan).0,
            rgb8(p.terminal_cyan).1,
            rgb8(p.terminal_cyan).2,
        )
        .white(
            rgb8(p.terminal_white).0,
            rgb8(p.terminal_white).1,
            rgb8(p.terminal_white).2,
        )
        .bright_black(
            bright(p.terminal_black).0,
            bright(p.terminal_black).1,
            bright(p.terminal_black).2,
        )
        .bright_red(
            bright(p.terminal_red).0,
            bright(p.terminal_red).1,
            bright(p.terminal_red).2,
        )
        .bright_green(
            bright(p.terminal_green).0,
            bright(p.terminal_green).1,
            bright(p.terminal_green).2,
        )
        .bright_yellow(
            bright(p.terminal_yellow).0,
            bright(p.terminal_yellow).1,
            bright(p.terminal_yellow).2,
        )
        .bright_blue(
            bright(p.terminal_blue).0,
            bright(p.terminal_blue).1,
            bright(p.terminal_blue).2,
        )
        .bright_magenta(
            bright(p.terminal_magenta).0,
            bright(p.terminal_magenta).1,
            bright(p.terminal_magenta).2,
        )
        .bright_cyan(
            bright(p.terminal_cyan).0,
            bright(p.terminal_cyan).1,
            bright(p.terminal_cyan).2,
        )
        .bright_white(
            bright(p.terminal_white).0,
            bright(p.terminal_white).1,
            bright(p.terminal_white).2,
        )
        .build()
}

/// 判断一次按键是否是“打开终端内搜索”（Ctrl+F）。组件不认识这个快捷键，会把它
/// 当控制字符写进 PTY，因此需要经由组件的按键钩子吞掉，再由宿主容器打开搜索栏。
fn is_search_shortcut(event: &KeyDownEvent) -> bool {
    let keystroke = &event.keystroke;
    keystroke.modifiers.control
        && !keystroke.modifiers.alt
        && !keystroke.modifiers.platform
        && keystroke.key.eq_ignore_ascii_case("f")
}

/// 判断一次按键是否是“复制”（Ctrl+C），与组件的判定保持一致。
fn is_copy_shortcut(event: &KeyDownEvent) -> bool {
    let keystroke = &event.keystroke;
    keystroke.modifiers.control
        && !keystroke.modifiers.alt
        && !keystroke.modifiers.platform
        && keystroke.key.eq_ignore_ascii_case("c")
}

/// 终端右键菜单文案（跟随应用语言）。Run/Maven 输出控制台也复用这一份。
pub(crate) fn context_menu_labels(cx: &App) -> gpui_xterm::ContextMenuLabels {
    gpui_xterm::ContextMenuLabels {
        copy: crate::i18n::menu_text(cx, "menu.copy").to_string(),
        paste: crate::i18n::menu_text(cx, "menu.paste").to_string(),
        clear: crate::i18n::menu_text(cx, "ui.clear").to_string(),
    }
}

// ---------------------------------------------------------------------------
// 视图层
// ---------------------------------------------------------------------------

/// 终端视图组件：会话编排 + `gpui_xterm` 组件 + 宿主能力（搜索/清屏/发送命令）。
pub struct TerminalView {
    /// `gpui_xterm` 组件实体；`None` 表示无会话（渲染空态）。
    xterm: Option<Entity<XtermView>>,
    /// 当前会话；`None` 表示尚未创建、创建失败或已被显式关闭。
    session: Option<TerminalSession>,
    /// 会话工作目录（宿主项目切换时更新）。
    working_dir: String,
    /// 会话代号：每次新建/关闭自增，事件泵据此丢弃过期会话的事件。
    session_seq: u64,
    /// 最近一次应用到组件的字号；设置变化时用于触发 `update_config`。
    applied_font_size: f32,
    /// 最近一次应用到组件的字体族；编辑器字体变化时用于触发 `update_config`。
    applied_font_family: String,
    /// 最近一次应用到组件的主题背景色；主题切换时用于触发 `update_config`，
    /// 让终端配色跟随深浅主题（否则切到深色后终端仍是浅色）。
    applied_background: Rgba,
    /// 终端内搜索状态。
    search: SearchState,
    /// 搜索输入框（懒创建，复用工作台唯一输入实现）。
    search_input: Option<SearchInput>,
    /// 搜索输入框事件订阅（必须与 `search_input` 同生命周期）。
    search_subscription: Option<Subscription>,
}

impl TerminalView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            xterm: None,
            session: None,
            working_dir,
            session_seq: 0,
            applied_font_size: settings::get(cx).terminal_font_size,
            applied_font_family: crate::fonts::mono_family(cx).to_string(),
            applied_background: theme::palette().background,
            search: SearchState::new(),
            search_input: None,
            search_subscription: None,
        };
        view.open_session(cx);
        view
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

    /// 已有会话时返回其生命周期状态。
    pub fn session_state(&self) -> SessionState {
        self.session
            .as_ref()
            .map(TerminalSession::state)
            .unwrap_or(SessionState::Closed)
    }

    /// 会话已经退出时给出退出码/信号，供状态区展示；仍在跑或空态返回 `None`。
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
    pub fn is_at_bottom(&self, cx: &App) -> bool {
        match &self.xterm {
            Some(xterm) => xterm.read(cx).state().display_offset() == 0,
            None => true,
        }
    }

    /// 打开会话；已有会话时不动。
    fn open_session(&mut self, cx: &mut Context<Self>) {
        if self.session.is_some() {
            return;
        }
        self.start_session(cx);
    }

    /// 创建 PTY 会话与 `gpui_xterm` 组件，并起退出事件泵。
    fn start_session(&mut self, cx: &mut Context<Self>) {
        let shell = resolve_shell(&settings::get(cx).terminal_default_shell_id);
        self.session_seq += 1;
        let seq = self.session_seq;
        let working_dir = self.working_dir.clone();
        match TerminalSession::new(&working_dir, &shell) {
            Ok((session, reader, rx)) => {
                let writer = session.writer();
                let resize = session.resize_callback();
                let config = self.xterm_config(cx);
                let xterm = cx.new(|cx| {
                    XtermView::new(writer, reader, config, cx)
                        .with_resize_callback(move |cols, rows| resize(cols, rows))
                        .with_key_handler(is_search_shortcut)
                        .with_context_menu_labels(context_menu_labels(cx))
                });
                self.applied_font_size = settings::get(cx).terminal_font_size;
                self.applied_font_family = crate::fonts::mono_family(cx).to_string();
                self.applied_background = theme::palette().background;
                self.xterm = Some(xterm);
                self.session = Some(session);
                Self::spawn_event_pump(rx, seq, cx);
            }
            Err(error) => {
                tracing::warn!("failed to open terminal pty session: {error}");
                self.xterm = None;
                self.session = None;
            }
        }
        cx.notify();
    }

    /// 主线程事件泵：后台收会话事件，回主线程更新视图。
    fn spawn_event_pump(rx: mpsc::Receiver<SessionEvent>, seq: u64, cx: &mut Context<Self>) {
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
            SessionEvent::Closed => {
                // 生命周期状态由会话层在等待线程里记录；这里只触发重绘，
                // 让宿主状态区展示退出码/信号。
                cx.notify();
                false
            }
        }
    }

    /// 新建会话：先关闭旧会话（回收子进程），再按当前尺寸与工作目录重开。
    pub fn restart(&mut self, cx: &mut Context<Self>) {
        self.teardown_session();
        self.open_session(cx);
    }

    /// 关闭会话：回收子进程并回到空态，且不再自动重建。
    pub fn close_session(&mut self, cx: &mut Context<Self>) {
        self.teardown_session();
        cx.notify();
    }

    /// 丢弃当前会话与组件实体（进程组终止与回收交给后台线程，见
    /// [`TerminalSession::stop_and_reap`] 的有界等待）。
    fn teardown_session(&mut self) {
        self.session_seq += 1;
        // 先丢组件实体：释放它持有的写端与读取线程。
        self.xterm = None;
        if let Some(session) = self.session.take() {
            // 句柄的 `Drop` 会有界等待子进程回收，不能占用 UI 线程；交给一次
            // 性后台线程立即 drop，效果与原地 drop 相同。
            thread::Builder::new()
                .name("lithe-terminal-reap".to_string())
                .spawn(move || drop(session))
                .ok();
        }
        self.search.clear();
        self.search_input = None;
        self.search_subscription = None;
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

    /// 清屏：向 shell 发送 Ctrl+L，由 shell 自身重画（等价于 IDEA 的 clear）。
    pub fn clear(&mut self, cx: &mut Context<Self>) {
        if self.is_running() {
            if let Some(session) = &self.session {
                let _ = session.write_bytes(&[0x0c]);
            }
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
        self.scroll_to_bottom(cx);
    }

    /// 视口滚到底部（回到底部动作、命令发送后自动跟随）。
    pub fn scroll_to_bottom(&self, cx: &mut Context<Self>) {
        if let Some(xterm) = self.xterm.clone() {
            xterm.update(cx, |view, cx| {
                view.state().scroll_to_bottom();
                cx.notify();
            });
        }
    }

    /// 生成组件配置：字号、回滚、内边距与主题调色板。
    fn xterm_config(&self, cx: &App) -> TerminalConfig {
        let s = settings::get(cx);
        TerminalConfig {
            cols: BOOTSTRAP_COLS,
            rows: BOOTSTRAP_ROWS,
            font_family: crate::fonts::mono_family(cx).to_string(),
            font_size: px(s.terminal_font_size),
            scrollback: s.terminal_scrollback.max(1),
            line_height_multiplier: 1.0,
            padding: Edges::all(px(GRID_PADDING)),
            colors: terminal_color_palette(),
        }
    }

    /// 打开终端内搜索：复用工作台唯一输入实现并聚焦。
    pub fn open_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.xterm.is_none() {
            return;
        }
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
        self.clear_selection(cx);
        search.focus(window, cx);
        cx.notify();
    }

    /// 关闭搜索栏并清除搜索态高亮，焦点回到终端组件。
    pub fn close_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search.clear();
        self.clear_selection(cx);
        self.search_subscription = None;
        self.search_input = None;
        if let Some(xterm) = self.xterm.clone() {
            let handle = xterm.read(cx).focus_handle().clone();
            window.focus(&handle, cx);
        }
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
        self.search.query = query;
        self.search.matches.clear();
        self.search.current = 0;
        self.search.truncated = false;
        if self.search.query.is_empty() {
            self.clear_selection(cx);
            cx.notify();
            return;
        }
        let mut regex = match RegexSearch::new(&self.search.query) {
            Ok(regex) => regex,
            Err(error) => {
                // 非法正则：当作无命中，并且不保留上一次的查询串。
                tracing::warn!("terminal search pattern rejected: {error}");
                self.search.clear();
                self.clear_selection(cx);
                cx.notify();
                return;
            }
        };
        if let Some(xterm) = self.xterm.clone() {
            let (matches, truncated) = xterm
                .read(cx)
                .state()
                .with_term(|term| collect_matches(term, &mut regex, SEARCH_MATCH_CAP));
            self.search.matches = matches;
            self.search.truncated = truncated;
            self.search.current = usize::from(!self.search.matches.is_empty());
        }
        self.highlight_current_match(cx);
        cx.notify();
    }

    /// 上一个/下一个命中：序号环绕 + 上游滚动 + 用 selection 高亮。
    fn step_search(&mut self, forward: bool, cx: &mut Context<Self>) {
        if self.search.is_empty() {
            return;
        }
        if self.search.total() == 0 {
            // 上一次查询判定无命中，而输出可能已经变化，重扫一次。
            let query = self.search.query.clone();
            self.search.query.clear();
            self.apply_search_query(query, cx);
            return;
        }
        self.search.step(forward);
        self.highlight_current_match(cx);
        cx.notify();
    }

    /// 用上游 selection 高亮当前命中并滚动到它；无命中则清除高亮。
    fn highlight_current_match(&mut self, cx: &mut Context<Self>) {
        let Some(xterm) = self.xterm.clone() else {
            return;
        };
        let current = self.search.current_match();
        xterm.update(cx, |view, cx| {
            view.state().with_term_mut(|term| match current {
                Some(found) => {
                    term.scroll_to_point(*found.start());
                    let mut selection =
                        Selection::new(SelectionType::Simple, *found.start(), Side::Left);
                    selection.update(*found.end(), Side::Right);
                    term.selection = Some(selection);
                }
                None => term.selection = None,
            });
            cx.notify();
        });
    }

    /// 清除组件内的选择高亮。
    fn clear_selection(&self, cx: &mut Context<Self>) {
        if let Some(xterm) = self.xterm.clone() {
            xterm.update(cx, |view, cx| {
                view.state().update_selection(None);
                cx.notify();
            });
        }
    }

    /// 把终端当前选区写入 GPUI 的平台剪贴板。
    ///
    /// 不改上游：组件自身的复制用临时 `arboard::Clipboard`，X11 下句柄一 drop 就
    /// 可能丢失数据（复制到其它应用读不到）。GPUI 的剪贴板由 App 进程长期持有并
    /// 持续服务选区请求，因此在宿主侧再写一次即可让复制真正生效。返回是否复制了
    /// 非空选区；无选区时返回 false，让 Ctrl+C 继续作为中断信号发给前台程序。
    fn copy_selection_to_clipboard(&self, cx: &mut Context<Self>) -> bool {
        let Some(xterm) = self.xterm.clone() else {
            return false;
        };
        let text = xterm
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

impl Render for TerminalView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 字号、编辑器字体或主题变化时把新配置推给组件（回滚缓冲只在建会话时生效）。
        let font_size = settings::get(cx).terminal_font_size;
        let font_family = crate::fonts::mono_family(cx).to_string();
        let background = theme::palette().background;
        if let Some(xterm) = self.xterm.clone() {
            let size_changed = (font_size - self.applied_font_size).abs() > f32::EPSILON;
            let family_changed = font_family != self.applied_font_family;
            let theme_changed = background != self.applied_background;
            if size_changed || family_changed || theme_changed {
                let config = self.xterm_config(cx);
                xterm.update(cx, |view, cx| view.update_config(config, cx));
                self.applied_font_size = font_size;
                self.applied_font_family = font_family;
                self.applied_background = background;
            }
        }

        let body: gpui_kit::AnyElement = match &self.xterm {
            Some(xterm) => {
                let search_bar = if self.search_visible() {
                    Some(self.render_search_bar(cx))
                } else {
                    None
                };
                div()
                    .relative()
                    .flex_1()
                    .w_full()
                    .min_h_0()
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        // 组件已用按键钩子吞掉 Ctrl+F，这里负责打开搜索栏并阻止
                        // 冒泡到工作台全局快捷键。
                        if is_search_shortcut(event) {
                            this.open_search(window, cx);
                            cx.stop_propagation();
                            return;
                        }
                        // Ctrl+C：组件用临时 arboard 句柄复制，X11 下可能丢数据；
                        // 有选区时这里再用 GPUI 剪贴板复制一次兜底。
                        if is_copy_shortcut(event) && this.copy_selection_to_clipboard(cx) {
                            cx.stop_propagation();
                        }
                    }))
                    // 左键抬起（拖选/双击选词结束）后同样兜底复制一次。
                    .on_mouse_up(
                        MouseButton::Left,
                        cx.listener(|this, _event, _window, cx| {
                            this.copy_selection_to_clipboard(cx);
                        }),
                    )
                    .child(xterm.clone())
                    .when_some(search_bar, |el, bar| el.child(bar))
                    .into_any_element()
            }
            None => self.render_closed_state(cx),
        };

        v_flex()
            .size_full()
            .bg(ThemeColors::background())
            .child(body)
    }
}

impl TerminalView {
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

    /// 渲染搜索栏（终端内搜索：浮层 + 计数 + 上/下一个 + 关闭）。做成浮层而不是
    /// 挤占一行高度，打开/关闭搜索不会触发终端 resize 与全屏 TUI 重排。
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

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::event::VoidListener;
    use alacritty_terminal::grid::Dimensions;
    use alacritty_terminal::term::Config;
    use alacritty_terminal::vte::ansi::Processor;

    /// 测试用网格尺寸（生产渲染尺寸由组件持有）。
    struct TestDims {
        cols: usize,
        rows: usize,
    }

    impl Dimensions for TestDims {
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

    /// 构造带输出的测试终端（复用与组件一致的解析路径）。
    fn term_with_output(bytes: &[u8]) -> Term<VoidListener> {
        let mut term = Term::new(
            Config {
                scrolling_history: 100,
                ..Config::default()
            },
            &TestDims { cols: 40, rows: 10 },
            VoidListener,
        );
        let mut processor: Processor = Processor::new();
        processor.advance(&mut term, bytes);
        term
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

    /// 查询串变化后重新收集命中，序号复位到首个命中，step 走到第二个。
    #[test]
    fn search_collects_matches_and_selects_first() {
        let term = term_with_output(b"alpha beta\r\nalpha gamma\r\n");
        let mut regex = RegexSearch::new("alpha").expect("valid regex");
        let (matches, truncated) = collect_matches(&term, &mut regex, SEARCH_MATCH_CAP);
        assert_eq!(matches.len(), 2);
        assert!(!truncated);
        assert_eq!(matches[0].start().line.0, 0);
        assert_eq!(matches[0].start().column.0, 0);
        assert_eq!(matches[1].start().line.0, 1);
    }

    /// 无命中时不产生高亮范围，计数显示 0/0。
    #[test]
    fn search_without_match_has_no_highlight() {
        let term = term_with_output(b"alpha\r\n");
        let mut regex = RegexSearch::new("omega").expect("valid regex");
        let (matches, _) = collect_matches(&term, &mut regex, SEARCH_MATCH_CAP);
        assert!(matches.is_empty());
        let mut state = SearchState::new();
        state.query = "omega".to_string();
        state.matches = matches;
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
            &TestDims { cols: 20, rows: 2 },
            VoidListener,
        );
        let mut processor: Processor = Processor::new();
        processor.advance(
            &mut term,
            b"needle one\r\nneedle two\r\nneedle three\r\nneedle four",
        );
        assert!(term.grid().history_size() > 0, "history must exist");
        let mut regex = RegexSearch::new("needle").expect("valid regex");
        let (matches, _) = collect_matches(&term, &mut regex, SEARCH_MATCH_CAP);
        assert_eq!(matches.len(), 4);
    }

    // ---- 主题映射 ----

    /// Rgba 浮点转 8 位整数：边界钳住，四舍五入。
    #[test]
    fn rgb8_clamps_and_rounds() {
        assert_eq!(
            rgb8(Rgba {
                r: 0.0,
                g: 0.5,
                b: 1.0,
                a: 1.0
            }),
            (0, 128, 255)
        );
        assert_eq!(
            rgb8(Rgba {
                r: 2.0,
                g: -1.0,
                b: 0.999,
                a: 1.0
            }),
            (255, 0, 255)
        );
    }
}
