//! 终端面板：用 gpui-webview 承载 xterm.js，PTY 交给 `lithe-terminal`。
//!
//! # 线程与重入边界
//!
//! wry 的 IPC 回调和自定义协议回调都可能不在 GPUI 主线程上，而且发生在 GPUI
//! 借用之外。因此 IPC 回调只解析 JSON 并投递到 `async_channel`；协议回调只读
//! 资源文件。任何实体更新和 `evaluate_script` 都只能在主线程的消息泵里做。
//!
//! # 启动时机
//!
//! 构造发生在 `App::run` 的可变借用内，此时 `cx.spawn` / `cx.background_spawn`
//! 会再次借 App 并触发 `RefCell already borrowed`。所以 `new` 只创建 WebView，
//! 不创建 PTY；首帧 `Render` 用 `cx.defer_in` 把「创建终端 + 启动消息泵」排到
//! 当前借用释放之后。`set_root` 清除终端状态后，下一次 `Render` 会以新的根
//! 目录重建。
//!
//! # 生命周期
//!
//! `Entity<WebView>` 和 `load_url` 都只在 [`TerminalPanel::new`] 里执行一次；
//! `render` 只负责布局，不触发导航。`Drop` 关闭当前终端，避免留下孤儿进程。

use std::borrow::Cow;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use base64::Engine as _;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AppContext as _, Context, Entity, Hsla, IntoElement, ParentElement, Render, Rgba, SharedString,
    Styled, Window, div, px,
};
use gpui_webview::WebView;
use lithe_terminal::{
    TerminalConfig, TerminalEvent, TerminalEventHandler, TerminalInput, TerminalManager,
    TerminalSize,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, current_tokens};
use serde_json::{Value, json};
use wry::http::{Request, Response, StatusCode, header::CONTENT_TYPE};

/// 面板唯一的自定义协议名。
const TERMINAL_PROTOCOL: &str = "lithe-terminal-gpui";
/// 初始 PTY 尺寸；前端 ready 后会按实际网格发送 resize。
const DEFAULT_ROWS: u16 = 24;
const DEFAULT_COLS: u16 = 80;
/// 默认回滚行数；与 `gpui/terminal/main.ts` 的 `DEFAULT_SCROLLBACK` 保持一致。
const DEFAULT_SCROLLBACK: u32 = 5000;

/// IPC 回调投递给主线程的消息。
///
/// 输出与前端输入都走同一个通道，但用变体区分，消息泵可以分别处理。终端
/// 事件和窗口事件混在一起是刻意的：它们都只做一件事，投递，不做 GPUI 操作。
enum PanelEvent {
    /// PTY 输出字节。
    Output(Vec<u8>),
    /// PTY 读线程报告的错误。
    TerminalError(String),
    /// 子进程退出。
    Exit {
        exit_code: Option<u32>,
        signal: Option<String>,
    },
    /// PTY 读线程关闭。
    Closed,
    /// 前端页面就绪。
    Ready,
    /// 前端输入文本。
    Input(String),
    /// 前端请求调整 PTY 网格。
    Resize { rows: u16, cols: u16 },
}

/// 面板顶部的一行状态。错误用 error token，退出/关闭用次要文字色。
#[derive(Clone)]
struct StatusLine {
    message: SharedString,
    is_error: bool,
}

/// 基于 WebView 的终端面板。
pub struct TerminalPanel {
    /// 工作区根；存在且是目录时作为 PTY 的 `working_directory`。
    root: PathBuf,
    /// WebView 只创建一次。资源缺失或平台构建失败时为 `None`。
    webview: Option<Entity<WebView>>,
    /// 构建期错误；与运行期状态分开，因为那时还没有页面。
    webview_error: Option<SharedString>,
    /// IPC 回调 -> 主线程消息泵。
    receiver: async_channel::Receiver<PanelEvent>,
    /// PTY 事件 handler 的投递端。
    sender: async_channel::Sender<PanelEvent>,
    /// 共享的终端管理器；PTY 连接由它持有。
    manager: Arc<TerminalManager>,
    /// 当前终端 id；`None` 表示尚未创建或已关闭。
    terminal_id: Option<String>,
    /// 消息泵只启动一次。
    pump_started: bool,
    /// 终端创建也只调度一次；`set_root` 会重置它。
    terminal_started: bool,
    /// 前端页面是否已 ready。ready 前的输出先缓存。
    ready: bool,
    /// ready 之前收到的输出。
    pending_output: Vec<u8>,
    /// 是否已经展示过退出状态；避免紧接着的 `Closed` 覆盖退出码。
    saw_exit: bool,
    /// 当前顶部状态行。
    status: Option<StatusLine>,
    /// 终端创建前收到的命令。`run_command` 在面板尚未初始化时把它暂存，
    /// `start_terminal` 成功后按顺序写入；`set_root` 会清空。
    pending_command: Option<String>,
    /// xterm 字号；设置页修改后由 `set_preferences` 写入。
    terminal_font_size: f32,
    /// xterm 回滚行数；设置页修改后由 `set_preferences` 写入。
    terminal_scrollback: u32,
}

impl TerminalPanel {
    pub fn new(root: PathBuf, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (sender, receiver) = async_channel::unbounded::<PanelEvent>();
        let asset_dir = terminal_asset_dir();
        let index_path = asset_dir.join("index.html");

        let (webview, webview_error) = if !index_path.is_file() {
            let message = format!("{}: {}", tr("Terminal unavailable"), index_path.display());
            (None, Some(SharedString::from(message)))
        } else {
            let builder = wry::WebViewBuilder::new();
            #[cfg(debug_assertions)]
            let builder = builder.with_devtools(true);

            let protocol_dir = asset_dir;
            let ipc_sender = sender.clone();
            let builder = builder
                .with_custom_protocol(TERMINAL_PROTOCOL.into(), move |_webview_id, request| {
                    asset_response(&protocol_dir, request)
                })
                .with_ipc_handler(move |request| {
                    // 只解析并投递。这里绝不能借 GPUI、创建终端或执行脚本。
                    if let Some(event) = decode_ipc(request.body()) {
                        let _ = ipc_sender.send_blocking(event);
                    }
                });

            match WebView::build(builder, window, cx) {
                Ok(mut built) => {
                    // 整个生命周期只在这里加载一次页面。
                    built.load_url(terminal_url());
                    (Some(cx.new(|_| built)), None)
                }
                Err(error) => (
                    None,
                    Some(SharedString::from(format!(
                        "{}: {error}",
                        tr("Terminal unavailable")
                    ))),
                ),
            }
        };

        Self {
            root,
            webview,
            webview_error,
            receiver,
            sender,
            manager: Arc::new(TerminalManager::new()),
            terminal_id: None,
            pump_started: false,
            terminal_started: false,
            ready: false,
            pending_output: Vec::new(),
            saw_exit: false,
            status: None,
            pending_command: None,
            terminal_font_size: LitheMetrics::CODE_FONT_SIZE,
            terminal_scrollback: DEFAULT_SCROLLBACK,
        }
    }

    /// 更新终端外观偏好并在页面就绪后立即下发。
    ///
    /// 主题切换或设置页修改字号/回滚行数时由工作台调用；页面尚未 ready 时
    /// 只更新状态，`ready` 消息会用最新值发送 `configure`。
    pub fn set_preferences(
        &mut self,
        font_size: f32,
        scrollback: u32,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // 与设置模型一致：字号限制在 9–32，回滚行数限制在 100–50000，
        // 避免设置文件里的异常值让终端不可用。
        self.terminal_font_size = if font_size.is_finite() {
            font_size.clamp(9.0, 32.0)
        } else {
            LitheMetrics::CODE_FONT_SIZE
        };
        self.terminal_scrollback = scrollback.clamp(100, 50_000);
        if self.ready && self.webview.is_some() {
            self.send_configure(cx);
        }
        cx.notify();
    }

    /// 切换工作区根。关闭旧终端并清空运行期状态，下一次 `Render` 重建。
    pub fn set_root(&mut self, root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        if let Some(id) = self.terminal_id.take() {
            let _ = self.manager.close_terminal(&id);
        }
        self.root = root;
        self.terminal_started = false;
        // 页面本身没有重新加载，`ready` 描述的是前端可用性而不是旧 PTY，
        // 因此保留它；否则新终端输出会永远堆在 ready 前的缓存里。
        self.pending_output.clear();
        self.saw_exit = false;
        self.status = None;
        // 旧工作区排队的命令不能在切换后的目录里执行。
        self.pending_command = None;
        // 旧终端的内容不应该留在新目录的屏幕里；页面未 ready 时由 JS 守卫忽略。
        self.evaluate("window.lithe && window.lithe.clear();".to_string(), cx);
        cx.notify();
    }

    /// 把键盘焦点交给 xterm.js。页面尚未加载时由 JS 侧的守卫安静忽略。
    pub fn focus(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        self.evaluate("window.lithe && window.lithe.focus();".to_string(), cx);
    }

    /// 清空终端的回滚缓冲（scrollback）。
    ///
    /// 只操作前端 xterm 的视图缓冲，不关闭也不重启 PTY：清屏是展示动作，
    /// 会话里正在运行的进程和输出流都必须保持原样。
    pub fn clear(&mut self, cx: &mut Context<Self>) {
        self.evaluate("window.lithe && window.lithe.clear();".to_string(), cx);
        cx.notify();
    }

    /// 控制原生 WebView 是否可见。
    ///
    /// 与 `EditorSurface::set_webview_visible` 相同：Windows 的 WebView 会盖住
    /// GPUI 覆盖层，工作台在打开设置/命令面板等覆盖层时临时隐藏它。
    pub fn set_webview_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        if let Some(webview) = self.webview.as_ref() {
            let _ = webview.update(cx, |webview, _| {
                let _ = webview.set_visible(visible);
                if !visible {
                    // 与编辑器相同：Windows 上隐藏 + 零 bounds，避免覆盖层
                    // 下方的点击被原生 WebView 吞掉。
                    let _ = webview.set_bounds(wry::Rect::default());
                }
            });
            cx.notify();
        }
    }

    /// 打开当前 WebView 的开发者工具（仅调试构建可用）。
    ///
    /// 与编辑器面板相同：只读调试能力，不影响发布构建。`wry::WebView::open_devtools`
    /// 只在 `debug_assertions` 或 `devtools` feature 下存在，非调试构建保留空实现。
    pub fn open_devtools(&mut self, cx: &mut Context<Self>) {
        let Some(webview) = self.webview.as_ref() else {
            return;
        };
        #[cfg(debug_assertions)]
        {
            // 原生 WebView 命令必须经由 GPUI 主线程的 update，与 `evaluate` 一致。
            let _ = webview.update(cx, |webview, _cx| webview.raw().open_devtools());
        }
        #[cfg(not(debug_assertions))]
        {
            let _ = &webview;
            let _ = &cx;
        }
    }

    /// 在终端里执行一条命令。
    ///
    /// 终端可能还没创建（面板尚未渲染，或 `set_root` 刚切换根目录）。这时把
    /// 命令记到 `pending_command`，等 `start_terminal` 创建 PTY 后补写；终端
    /// 已创建时直接写 PTY。输出仍走既有的 IPC/事件泵链路，页面 ready 前的
    /// 字节会进入 `pending_output` 缓存。
    pub fn run_command(&mut self, command: String, _window: &mut Window, cx: &mut Context<Self>) {
        // 去掉调用方可能附带的换行，避免写入两个空行；保留命令内部空白。
        let command = command
            .trim_end_matches(|character| character == '\r' || character == '\n')
            .to_string();
        if command.is_empty() {
            return;
        }

        if self.terminal_id.is_some() {
            self.write_command(&command, cx);
            return;
        }

        // 终端尚未创建：连续点击时保留每一条命令，终端就绪后按顺序执行。
        self.pending_command = Some(match self.pending_command.take() {
            Some(pending) => format!("{pending}\n{command}"),
            None => command,
        });
        cx.notify();
    }

    /// 把一条命令写入当前 PTY。调用方保证终端 id 存在。
    fn write_command(&mut self, command: &str, cx: &mut Context<Self>) {
        let Some(id) = self.terminal_id.clone() else {
            return;
        };
        if let Err(error) = self.manager.write_to_terminal(
            &id,
            TerminalInput::Text {
                data: format!("{command}\n"),
            },
        ) {
            self.set_error(format!("{}: {error}", tr("Terminal unavailable")), cx);
        }
    }

    /// 终端创建后补写 `run_command` 暂存的命令。
    fn flush_pending_command(&mut self, cx: &mut Context<Self>) {
        let Some(command) = self.pending_command.take() else {
            return;
        };
        if self.terminal_id.is_none() {
            // 创建失败或还没创建：留在队列里，下一次成功创建时再写。
            self.pending_command = Some(command);
            return;
        }
        self.write_command(&command, cx);
    }

    /// 首帧只调度一次终端创建和消息泵。
    fn ensure_started(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.pump_started {
            self.pump_started = true;
            self.terminal_started = true;

            let receiver = self.receiver.clone();
            cx.defer_in(window, move |this, window, cx| {
                if this.webview.is_some() {
                    this.start_terminal(window, cx);
                }
                // IPC 与 PTY 事件都在这里回到主线程处理。
                cx.spawn_in(window, async move |this, cx| {
                    while let Ok(event) = receiver.recv().await {
                        if this
                            .update_in(cx, |this, _window, cx| this.handle_event(event, cx))
                            .is_err()
                        {
                            break;
                        }
                    }
                })
                .detach();
            });
        } else if !self.terminal_started {
            // `set_root` 之后重建终端；消息泵已经在运行。
            self.terminal_started = true;
            cx.defer_in(window, move |this, window, cx| {
                if this.webview.is_some() {
                    this.start_terminal(window, cx);
                }
            });
        }
    }

    /// 创建 PTY。只在 `defer_in` 回调或主线程 update 里调用。
    fn start_terminal(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        if self.terminal_id.is_some() || self.webview.is_none() {
            return;
        }

        self.status = None;
        self.saw_exit = false;
        // 丢弃旧终端在关闭过程中已经进入 channel、但还没来得及展示的输出。
        self.pending_output.clear();

        let working_directory = if self.root.is_dir() {
            Some(self.root.to_string_lossy().into_owned())
        } else {
            None
        };
        let config = TerminalConfig {
            working_directory,
            shell: None,
            environment: None,
            command: None,
            args: None,
            size: TerminalSize {
                rows: DEFAULT_ROWS,
                cols: DEFAULT_COLS,
                pixel_width: 0,
                pixel_height: 0,
            },
            term_program_version: None,
        };

        let sender = self.sender.clone();
        let handler: TerminalEventHandler = Arc::new(move |_id, event| {
            // handler 运行在 PTY 读线程上：只入 channel，绝不碰 GPUI。
            let message = match event {
                TerminalEvent::Output { data } => PanelEvent::Output(data),
                TerminalEvent::Error { message } => PanelEvent::TerminalError(message),
                TerminalEvent::Exit { exit_code, signal } => PanelEvent::Exit { exit_code, signal },
                TerminalEvent::Closed => PanelEvent::Closed,
            };
            let _ = sender.send_blocking(message);
            true
        });

        match self.manager.create_terminal(config, handler) {
            Ok(id) => self.terminal_id = Some(id),
            Err(error) => {
                self.status = Some(StatusLine {
                    message: SharedString::from(format!("{}: {error}", tr("Terminal unavailable"))),
                    is_error: true,
                });
            }
        }
        // `run_command` 在终端创建前暂存的命令在这里补写；创建失败时保持
        // 挂起，等下一次重建。
        self.flush_pending_command(cx);
        cx.notify();
    }

    /// 在主线程处理一条 IPC 或 PTY 事件。
    fn handle_event(&mut self, event: PanelEvent, cx: &mut Context<Self>) {
        match event {
            PanelEvent::Output(data) => {
                if self.ready {
                    self.write_output(&data, cx);
                } else {
                    self.pending_output.extend_from_slice(&data);
                }
            }
            PanelEvent::Ready => {
                self.ready = true;
                // 先下发主题和字体，再把 ready 前的输出按原顺序补上。
                self.send_configure(cx);
                if !self.pending_output.is_empty() {
                    let data = std::mem::take(&mut self.pending_output);
                    self.write_output(&data, cx);
                }
                // 页面就绪前暂存的命令也在此时兜底补写（通常已在创建终端时
                // 写入，此处对空队列无副作用）。
                self.flush_pending_command(cx);
            }
            PanelEvent::Input(data) => {
                let Some(id) = self.terminal_id.clone() else {
                    return;
                };
                if let Err(error) = self
                    .manager
                    .write_to_terminal(&id, TerminalInput::Text { data })
                {
                    self.set_error(format!("{}: {error}", tr("Terminal unavailable")), cx);
                }
            }
            PanelEvent::Resize { rows, cols } => {
                let Some(id) = self.terminal_id.clone() else {
                    return;
                };
                let size = TerminalSize {
                    rows: rows.max(1),
                    cols: cols.max(1),
                    pixel_width: 0,
                    pixel_height: 0,
                };
                if let Err(error) = self.manager.resize_terminal(&id, size) {
                    self.set_error(format!("{}: {error}", tr("Terminal unavailable")), cx);
                }
            }
            PanelEvent::TerminalError(message) => {
                self.set_error(message, cx);
            }
            PanelEvent::Exit { exit_code, signal } => {
                self.saw_exit = true;
                let is_error = exit_code.is_some_and(|code| code != 0) || signal.is_some();
                let detail = match (exit_code, signal) {
                    (Some(code), _) => Some(format!("{} {code}", tr("Exit code"))),
                    (None, Some(signal)) => Some(signal),
                    (None, None) => None,
                };
                let message = match detail {
                    Some(detail) => format!("{} ({detail})", tr("Terminal exited")),
                    None => tr("Terminal exited").to_string(),
                };
                self.status = Some(StatusLine {
                    message: SharedString::from(message),
                    is_error,
                });
                cx.notify();
            }
            PanelEvent::Closed => {
                // 读线程可能先报 Error/Exit 再报 Closed；不要覆盖更具体的那一行。
                if !self.saw_exit && self.status.is_none() {
                    self.status = Some(StatusLine {
                        message: SharedString::from(tr("Terminal closed")),
                        is_error: false,
                    });
                    cx.notify();
                }
            }
        }
    }

    /// 主题切换后重新下发 xterm 配色。
    ///
    /// 与 `EditorSurface::set_preferences` 同理：主题变化不改变 PTY 会话，
    /// 只更新页面外观。
    pub fn refresh_theme(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        if self.webview.is_some() {
            self.send_configure(cx);
        }
        cx.notify();
    }

    /// 终端的 CSS 字体族。
    ///
    /// 只下发 `"JetBrains Mono"` 时，WebView2 在字体未安装的情况下会回退到
    /// 默认比例字体，字符宽度被拉宽（看起来像“全角”）。Tauri 的
    /// `resolve-font.ts` 也做同样的平台回退；这里用 CSS 字体列表完成：
    /// 主字体 → 平台原生等宽 → 通用 monospace。
    fn terminal_font_family() -> &'static str {
        #[cfg(target_os = "windows")]
        {
            "\"JetBrains Mono\", Consolas, \"Courier New\", monospace"
        }
        #[cfg(target_os = "macos")]
        {
            "\"JetBrains Mono\", Menlo, monospace"
        }
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        {
            "\"JetBrains Mono\", \"Liberation Mono\", \"DejaVu Sans Mono\", monospace"
        }
    }

    /// 通过 `current_tokens` 生成 xterm.js 主题并下发。
    fn send_configure(&mut self, cx: &mut Context<Self>) {
        let tokens = current_tokens(cx);
        let payload = json!({
            "dark": tokens.editor.l <= 0.5,
            "background": hex_color(tokens.editor),
            "foreground": hex_color(tokens.primary_text),
            "cursor": hex_color(tokens.accent),
            "selection": hex_color(tokens.subtle_selection),
            "fontFamily": Self::terminal_font_family(),
            "fontSize": self.terminal_font_size,
            "scrollback": self.terminal_scrollback,
        });
        self.evaluate(
            format!(
                "window.lithe && window.lithe.configure({});",
                js_json(&payload)
            ),
            cx,
        );
    }

    /// 输出字节用 base64 传给 JS，避免 JSON 数组膨胀。
    fn write_output(&mut self, data: &[u8], cx: &mut Context<Self>) {
        if data.is_empty() {
            return;
        }
        let encoded = base64::engine::general_purpose::STANDARD.encode(data);
        self.evaluate(
            format!("window.lithe && window.lithe.write(\"{encoded}\");"),
            cx,
        );
    }

    /// 唯一允许调用 `evaluate_script` 的地方。调用方必须已经在主线程的
    /// update/render 回调里。
    fn evaluate(&mut self, script: String, cx: &mut Context<Self>) {
        let Some(webview) = self.webview.clone() else {
            return;
        };
        let result = webview.update(cx, |webview, _cx| webview.raw().evaluate_script(&script));
        if let Err(error) = result {
            self.set_error(format!("{}: {error}", tr("Terminal unavailable")), cx);
        }
    }

    fn set_error(&mut self, message: impl Into<SharedString>, cx: &mut Context<Self>) {
        self.status = Some(StatusLine {
            message: message.into(),
            is_error: true,
        });
        cx.notify();
    }
}

impl Drop for TerminalPanel {
    fn drop(&mut self) {
        if let Some(id) = self.terminal_id.take() {
            let _ = self.manager.close_terminal(&id);
        }
    }
}

impl Render for TerminalPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 首帧（以及 set_root 之后的首帧）在这里排定终端创建和消息泵。
        self.ensure_started(window, cx);

        let tokens = current_tokens(cx);
        let status = self.status.clone();

        match self.webview.as_ref() {
            Some(webview) => {
                let webview = webview.clone();
                div()
                    .size_full()
                    .flex()
                    .flex_col()
                    .bg(tokens.editor)
                    .when_some(status, |this, status| {
                        this.child(status_strip(status, tokens))
                    })
                    .child(div().flex_1().min_h(px(0.0)).child(webview))
            }
            None => {
                let message = self
                    .webview_error
                    .clone()
                    .unwrap_or_else(|| SharedString::from(tr("Terminal unavailable")));
                div()
                    .size_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(tokens.editor)
                    .px(px(16.0))
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(message)
            }
        }
    }
}

/// 顶部状态条。单独占一行，避免被原生 WebView 覆盖。
fn status_strip(status: StatusLine, tokens: LitheTokens) -> impl IntoElement {
    div()
        .w_full()
        .flex_shrink_0()
        .px(px(10.0))
        .py(px(6.0))
        .bg(tokens.raised)
        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
        .text_color(if status.is_error {
            tokens.error
        } else {
            tokens.secondary_text
        })
        .child(status.message)
}

// ---------------------------------------------------------------------------
// IPC 解析
// ---------------------------------------------------------------------------

/// 解析 `window.ipc.postMessage(JSON)`。未知或畸形消息返回 `None`。
fn decode_ipc(body: &str) -> Option<PanelEvent> {
    let value: Value = serde_json::from_str(body).ok()?;
    match value.get("type")?.as_str()? {
        "ready" => Some(PanelEvent::Ready),
        "input" => Some(PanelEvent::Input(value.get("data")?.as_str()?.to_string())),
        "resize" => Some(PanelEvent::Resize {
            rows: dimension(value.get("rows"), DEFAULT_ROWS),
            cols: dimension(value.get("cols"), DEFAULT_COLS),
        }),
        _ => None,
    }
}

/// 读取网格尺寸。缺省、零值或超出 `u16` 时回退到默认值；PTY 侧还会再规范一次。
fn dimension(value: Option<&Value>, fallback: u16) -> u16 {
    value
        .and_then(Value::as_u64)
        .and_then(|number| u16::try_from(number).ok())
        .filter(|number| *number > 0)
        .unwrap_or(fallback)
}

// ---------------------------------------------------------------------------
// 资源目录与自定义协议
// ---------------------------------------------------------------------------

/// 终端资源目录：环境变量优先，否则 `CARGO_MANIFEST_DIR/../terminal/dist`。
fn terminal_asset_dir() -> PathBuf {
    if let Some(directory) = std::env::var_os("LITHE_GPUI_TERMINAL_DIR") {
        if !directory.is_empty() {
            return PathBuf::from(directory);
        }
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../terminal/dist")
}

/// 自定义协议 URL。Windows 的 WebView2 只认 `http://<scheme>.localhost/...`。
fn terminal_url() -> &'static str {
    #[cfg(target_os = "windows")]
    {
        "http://lithe-terminal-gpui.localhost/index.html"
    }
    #[cfg(not(target_os = "windows"))]
    {
        "lithe-terminal-gpui://localhost/index.html"
    }
}

/// 处理一次协议请求。运行在 wry 的协议线程，不能碰 GPUI。
fn asset_response(root: &Path, request: Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    match read_asset(root, request.uri().path()) {
        Ok((content_type, body)) => build_response(StatusCode::OK, content_type, body),
        Err(status) => {
            let body = if status == StatusCode::FORBIDDEN {
                b"Forbidden".to_vec()
            } else if status == StatusCode::NOT_FOUND {
                b"Not Found".to_vec()
            } else {
                b"Internal Server Error".to_vec()
            };
            build_response(status, "text/plain; charset=utf-8", body)
        }
    }
}

fn build_response(
    status: StatusCode,
    content_type: &'static str,
    body: Vec<u8>,
) -> Response<Cow<'static, [u8]>> {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, content_type)
        .header("Cache-Control", "no-cache")
        .body(Cow::Owned(body))
        .unwrap_or_else(|_| Response::new(Cow::Borrowed(&b""[..])))
}

/// 读取资源目录内的文件。拒绝 `..`、绝对路径、Windows 盘符/反斜杠，并在
/// 规范化后再次确认文件没有通过符号链接逃逸出资源目录。
fn read_asset(root: &Path, uri_path: &str) -> Result<(&'static str, Vec<u8>), StatusCode> {
    let relative = safe_relative_path(uri_path).ok_or(StatusCode::FORBIDDEN)?;

    let canonical_root =
        std::fs::canonicalize(root).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let candidate = canonical_root.join(&relative);
    let canonical = std::fs::canonicalize(&candidate).map_err(|_| StatusCode::NOT_FOUND)?;
    if !canonical.starts_with(&canonical_root) {
        return Err(StatusCode::FORBIDDEN);
    }
    if !canonical.is_file() {
        return Err(StatusCode::NOT_FOUND);
    }

    let body = std::fs::read(&canonical).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok((content_type_for(&relative), body))
}

/// `/` 是 index.html；其余路径只允许普通组件。
fn safe_relative_path(uri_path: &str) -> Option<PathBuf> {
    let decoded = percent_decode(uri_path)?;
    // `\` 和 `:` 在不同平台上语义不一致，直接拒绝最省心。
    if decoded.contains('\0') || decoded.contains('\\') || decoded.contains(':') {
        return None;
    }

    let trimmed = decoded.trim_start_matches('/');
    if trimmed.is_empty() {
        return Some(PathBuf::from("index.html"));
    }

    let mut relative = PathBuf::new();
    for component in Path::new(trimmed).components() {
        match component {
            Component::Normal(part) => relative.push(part),
            Component::CurDir => {}
            // ParentDir、RootDir、Prefix 都不允许。
            _ => return None,
        }
    }

    if relative.as_os_str().is_empty() {
        None
    } else {
        Some(relative)
    }
}

fn content_type_for(path: &Path) -> &'static str {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("");
    match extension.to_ascii_lowercase().as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "wasm" => "application/wasm",
        "json" | "map" => "application/json; charset=utf-8",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        _ => "application/octet-stream",
    }
}

/// 解码 URI path 里的 `%XX`；非法编码返回 `None`。
fn percent_decode(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return None;
            }
            let high = hex_value(bytes[index + 1])?;
            let low = hex_value(bytes[index + 2])?;
            decoded.push((high << 4) | low);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }

    String::from_utf8(decoded).ok()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// JS 字面量与颜色
// ---------------------------------------------------------------------------

/// 把 `Value` 直接嵌入脚本；`serde_json::Value` 的 Display 就是合法 JSON。
fn js_json(value: &Value) -> String {
    escape_line_separators(&value.to_string())
}

/// U+2028/U+2029 会把 JS 字符串字面量拆成两行，显式转义。
fn escape_line_separators(text: &str) -> String {
    text.replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029")
}

/// 把 `Hsla` 转成 xterm.js 需要的 `#RRGGBB`。
fn hex_color(color: Hsla) -> String {
    let rgba = Rgba::from(color);
    format!(
        "#{:02X}{:02X}{:02X}",
        color_channel(rgba.r),
        color_channel(rgba.g),
        color_channel(rgba.b)
    )
}

fn color_channel(value: f32) -> u8 {
    (value.clamp(0.0, 1.0) * 255.0).round() as u8
}
