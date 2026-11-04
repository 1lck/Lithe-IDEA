//! 纯原生 GPUI 终端面板。
//!
//! 基于 `alacritty_terminal` 的 VT 状态机与 `lithe-terminal` 的 PTY 管理器，
//! 完全采用 GPUI 原生画布与文字系统进行渲染，不再依赖任何 WebView 或 xterm.js。

pub mod color;
pub mod keys;
pub mod model;
pub mod view;

use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gpui_kit::component::v_flex;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, FocusHandle, IntoElement, ParentElement, Render,
    SharedString, Styled, Window, div, px,
};
use lithe_terminal::{
    TerminalConfig, TerminalEvent, TerminalEventHandler, TerminalInput, TerminalManager,
    TerminalSize,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, current_tokens};

use self::model::TerminalModel;

/// 初始 PTY 尺寸。
const DEFAULT_ROWS: u16 = 24;
const DEFAULT_COLS: u16 = 80;
/// 默认回滚行数。
const DEFAULT_SCROLLBACK: u32 = 5000;
/// PTY 输出合批窗口：与运行控制台一致，避免每个数据块都触发一次整屏重排。
const OUTPUT_FLUSH_INTERVAL: Duration = Duration::from_millis(16);
/// 合批缓冲上限；一次输出超过它时立即刷新，避免缓冲区无界增长。
const MAX_PENDING_OUTPUT: usize = 1 << 20;

/// 内部事件流消息。
///
/// 每条事件都带 `generation`：每次启动新 PTY 递增，用于丢弃旧会话的迟到事件。
/// 用代数而不是会话 ID 字符串，避免在 PTY 输出这种高频路径上逐条分配 `String`。
enum PanelEvent {
    /// PTY 输出字节。
    Output { generation: u64, data: Vec<u8> },
    /// PTY 错误。
    TerminalError(String),
    /// 子进程退出。
    Exit {
        /// 来源会话代次；重启后用于丢弃旧会话的迟到事件。
        generation: u64,
        exit_code: Option<u32>,
        signal: Option<String>,
    },
    /// PTY 关闭。
    Closed {
        /// 来源会话代次；重启后用于丢弃旧会话的迟到事件。
        generation: u64,
    },
    /// 用户键盘输入字节。
    Input(Vec<u8>),
    /// 视口尺寸变化。
    Resize { rows: u16, cols: u16 },
    /// 鼠标滚轮滚动。
    Scroll(i32),
}

/// 面板顶部的状态提示。
#[derive(Clone)]
struct StatusLine {
    message: SharedString,
    is_error: bool,
}

/// 纯原生 GPUI 终端面板。
pub struct TerminalPanel {
    /// 工作区根目录；PTY 会以它作为工作目录。
    root: PathBuf,
    /// 终端模型（持有 VT 状态机与字符网格）。
    model: TerminalModel,
    /// GPUI 键盘焦点句柄。
    focus_handle: FocusHandle,
    /// 内部事件发送端。
    sender: async_channel::Sender<PanelEvent>,
    /// 内部事件接收端。
    receiver: async_channel::Receiver<PanelEvent>,
    /// 画布视图传回的 resize 调整端。
    resize_sender: async_channel::Sender<(u16, u16)>,
    /// 画布视图传回的输入发送端。
    key_sender: async_channel::Sender<Vec<u8>>,
    /// 画布视图传回的滚动发送端。
    scroll_sender: async_channel::Sender<i32>,
    /// 共享终端管理器。
    manager: Arc<TerminalManager>,
    /// 当前活跃终端 ID。
    terminal_id: Option<String>,
    /// 会话代次：每次启动新 PTY 递增，用于识别并丢弃旧会话的迟到事件。
    session_generation: u64,
    /// 尚未合入 VT 状态机的 PTY 输出。
    pending_output: Vec<u8>,
    /// 是否已经排定一次合批刷新。
    output_flush_scheduled: bool,
    /// 最近一次启动失败的原因；用于画布上的居中提示。
    launch_error: Option<SharedString>,
    /// 关闭会话回调；由工作台注入，标签菜单的 Close Terminal 复用同一入口。
    close_handler: Option<Rc<dyn Fn(&mut Window, &mut App)>>,
    /// 事件泵是否已启动。
    pump_started: bool,
    /// 终端会话是否已排定启动。
    terminal_started: bool,
    /// 是否已展示退出状态。
    saw_exit: bool,
    /// 顶部状态条。
    status: Option<StatusLine>,
    /// 暂存的执行命令。
    pending_command: Option<String>,
    /// 终端字号。
    terminal_font_size: f32,
    /// 回滚行数。
    terminal_scrollback: u32,
    /// 指定的 shell 路径。
    shell: Option<String>,
}

impl TerminalPanel {
    /// 创建终端面板。
    pub fn new(root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (sender, receiver) = async_channel::unbounded::<PanelEvent>();

        let (resize_sender, resize_receiver) = async_channel::unbounded::<(u16, u16)>();
        let (key_sender, key_receiver) = async_channel::unbounded::<Vec<u8>>();
        let (scroll_sender, scroll_receiver) = async_channel::unbounded::<i32>();

        // 管道转发到统一事件泵
        let pipe_sender_1 = sender.clone();
        cx.background_spawn(async move {
            while let Ok((cols, rows)) = resize_receiver.recv().await {
                let _ = pipe_sender_1.send(PanelEvent::Resize { rows, cols }).await;
            }
        })
        .detach();

        let pipe_sender_2 = sender.clone();
        cx.background_spawn(async move {
            while let Ok(bytes) = key_receiver.recv().await {
                let _ = pipe_sender_2.send(PanelEvent::Input(bytes)).await;
            }
        })
        .detach();

        let pipe_sender_3 = sender.clone();
        cx.background_spawn(async move {
            while let Ok(delta) = scroll_receiver.recv().await {
                let _ = pipe_sender_3.send(PanelEvent::Scroll(delta)).await;
            }
        })
        .detach();

        let focus_handle = cx.focus_handle();
        let model = TerminalModel::new(
            DEFAULT_COLS as usize,
            DEFAULT_ROWS as usize,
            DEFAULT_SCROLLBACK,
        );

        Self {
            root,
            model,
            focus_handle,
            sender,
            receiver,
            resize_sender,
            key_sender,
            scroll_sender,
            manager: Arc::new(TerminalManager::new()),
            terminal_id: None,
            session_generation: 0,
            pending_output: Vec::new(),
            output_flush_scheduled: false,
            launch_error: None,
            close_handler: None,
            pump_started: false,
            terminal_started: false,
            saw_exit: false,
            status: None,
            pending_command: None,
            terminal_font_size: LitheMetrics::CODE_FONT_SIZE,
            terminal_scrollback: DEFAULT_SCROLLBACK,
            shell: None,
        }
    }

    /// 更新终端字号与回滚偏好设置。
    pub fn set_preferences(
        &mut self,
        font_size: f32,
        scrollback: u32,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.terminal_font_size = if font_size.is_finite() {
            font_size.clamp(9.0, 32.0)
        } else {
            LitheMetrics::CODE_FONT_SIZE
        };
        self.terminal_scrollback = scrollback.clamp(100, 50_000);
        self.model.set_scrollback(self.terminal_scrollback);
        cx.notify();
    }

    /// 切换 shell。
    pub fn set_shell(
        &mut self,
        shell: Option<String>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.shell == shell {
            return;
        }
        self.shell = shell;
        self.reset_session();
        cx.notify();
    }

    /// 获取当前 shell。
    pub fn shell(&self) -> Option<&str> {
        self.shell.as_deref()
    }

    /// 切换工作区根目录。
    pub fn set_root(&mut self, root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        self.root = root;
        self.reset_session();
        cx.notify();
    }

    /// 聚焦终端视图。
    pub fn focus(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus_handle, cx);
        cx.notify();
    }

    /// 清空终端屏幕。
    pub fn clear(&mut self, cx: &mut Context<Self>) {
        self.model.clear();
        cx.notify();
    }

    /// 关闭当前 PTY、清空屏幕与状态，下一帧自动重新启动一个会话。
    pub fn restart(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        // 不在这里直接启动：交给下一帧的 `ensure_started`，避免在事件回调或渲染期间重入。
        self.reset_session();
        cx.notify();
    }

    /// 关闭当前 PTY、清空屏幕，并让旧会话的在途事件全部失效。
    ///
    /// 重启、换 shell、换工作区目录都要求“旧会话不再影响新会话”：关闭 PTY 后
    /// 把 `session_generation` 加一，已经在事件通道里的旧输出 / 退出 / 关闭事件
    /// 会被 `is_stale_generation` 丢弃，不会写进刚清空的屏幕或清掉新会话 ID。
    fn reset_session(&mut self) {
        if let Some(id) = self.terminal_id.take() {
            let _ = self.manager.close_terminal(&id);
        }
        self.session_generation = self.session_generation.wrapping_add(1);
        self.terminal_started = false;
        self.saw_exit = false;
        self.status = None;
        self.pending_command = None;
        self.pending_output.clear();
        self.launch_error = None;
        self.model.clear();
    }

    /// 向当前 PTY 发送 Ctrl+C（ETX，0x03），不关闭会话。
    pub fn interrupt(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.terminal_id.clone() else {
            return;
        };
        // 直接发送单个控制字节，无需经过 UTF-8 文本转换。
        if let Err(error) = self
            .manager
            .write_to_terminal(&id, TerminalInput::Binary { data: vec![0x03] })
        {
            self.set_error(format!("{}: {error}", tr("Terminal unavailable")), cx);
        }
    }

    /// 当前是否持有运行中的 PTY 会话。
    pub fn is_running(&self) -> bool {
        self.terminal_id.is_some()
    }

    /// 会话是否已经自行退出（shell 结束）。
    ///
    /// 工作台据此移除对应标签页，对齐 macOS `handleTerminalSessionEnded`
    /// 在 shell 退出后关闭会话的行为。用户主动重启时 `reset_session` 会清掉
    /// `saw_exit`，因此不会把「重启」误判成「退出」。
    pub fn has_exited(&self) -> bool {
        self.saw_exit && self.terminal_id.is_none()
    }

    /// 注入关闭回调。标签栏菜单的 Close Terminal 走工作台同一条关闭入口。
    pub fn set_close_handler(&mut self, handler: Rc<dyn Fn(&mut Window, &mut App)>) {
        self.close_handler = Some(handler);
    }

    /// 把文本写进 PTY（菜单里的 Paste）。
    ///
    /// 会话未运行时忽略：macOS 的粘贴同样只作用于当前运行中的终端。
    pub fn paste_text(&mut self, text: &str, cx: &mut Context<Self>) {
        if text.is_empty() {
            return;
        }
        let Some(id) = self.terminal_id.clone() else {
            return;
        };
        if let Err(error) = self.manager.write_to_terminal(
            &id,
            TerminalInput::Text {
                data: text.to_string(),
            },
        ) {
            self.set_error(format!("{}: {error}", tr("Terminal unavailable")), cx);
        }
    }

    /// 兼容接口：纯原生无需 WebView 调试工具。
    pub fn open_devtools(&mut self, _cx: &mut Context<Self>) {}

    /// 在终端中执行命令。
    pub fn run_command(&mut self, command: String, _window: &mut Window, cx: &mut Context<Self>) {
        let command = command
            .trim_end_matches(|c| c == '\r' || c == '\n')
            .to_string();
        if command.is_empty() {
            return;
        }

        if self.terminal_id.is_some() {
            self.write_command(&command, cx);
            return;
        }

        self.pending_command = Some(match self.pending_command.take() {
            Some(pending) => format!("{pending}\n{command}"),
            None => command,
        });
        cx.notify();
    }

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

    fn flush_pending_command(&mut self, cx: &mut Context<Self>) {
        let Some(command) = self.pending_command.take() else {
            return;
        };
        if self.terminal_id.is_none() {
            self.pending_command = Some(command);
            return;
        }
        self.write_command(&command, cx);
    }

    /// 把 PTY 输出放进合批缓冲，窗口到期后一次性写入 VT 状态机。
    ///
    /// `alacritty_terminal` 每次解析都可能触发整屏重排；编译输出或 `cat`
    /// 大文件时逐块重排会把 UI 线程拖住，这里按 16ms 合并，一帧最多一次。
    fn queue_output(&mut self, data: &[u8], cx: &mut Context<Self>) {
        self.pending_output.extend_from_slice(data);
        if self.pending_output.len() >= MAX_PENDING_OUTPUT {
            self.flush_output(cx);
            return;
        }
        if self.output_flush_scheduled {
            return;
        }
        self.output_flush_scheduled = true;
        cx.spawn(async move |this, cx| {
            // 计时器在后台执行器上，不占用 UI 线程。
            cx.background_executor().timer(OUTPUT_FLUSH_INTERVAL).await;
            let _ = this.update(cx, |this, cx| {
                this.output_flush_scheduled = false;
                this.flush_output(cx);
            });
        })
        .detach();
    }

    /// 一次性把合批缓冲写进 VT 状态机并请求重绘。
    fn flush_output(&mut self, cx: &mut Context<Self>) {
        if self.pending_output.is_empty() {
            return;
        }
        let data = std::mem::take(&mut self.pending_output);
        self.model.process_bytes(&data);
        cx.notify();
    }

    fn ensure_started(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.pump_started {
            self.pump_started = true;
            self.terminal_started = true;

            let receiver = self.receiver.clone();
            cx.defer_in(window, move |this, window, cx| {
                this.start_terminal(window, cx);
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
            self.terminal_started = true;
            cx.defer_in(window, move |this, window, cx| {
                this.start_terminal(window, cx);
            });
        }
    }

    fn start_terminal(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        if self.terminal_id.is_some() {
            return;
        }

        self.status = None;
        self.saw_exit = false;

        let working_directory = if self.root.is_dir() {
            Some(self.root.to_string_lossy().into_owned())
        } else {
            None
        };
        let size = TerminalSize {
            rows: self.model.screen_lines() as u16,
            cols: self.model.columns() as u16,
            pixel_width: 0,
            pixel_height: 0,
        };
        let config = TerminalConfig {
            working_directory,
            shell: self.shell.clone(),
            environment: None,
            command: None,
            args: None,
            size,
            term_program_version: None,
        };

        let sender = self.sender.clone();
        self.session_generation += 1;
        let generation = self.session_generation;
        let handler: TerminalEventHandler = Arc::new(move |_id, event| {
            let panel_event = match event {
                TerminalEvent::Output { data } => PanelEvent::Output { generation, data },
                TerminalEvent::Error { message } => PanelEvent::TerminalError(message),
                TerminalEvent::Exit { exit_code, signal } => PanelEvent::Exit {
                    generation,
                    exit_code,
                    signal,
                },
                TerminalEvent::Closed => PanelEvent::Closed { generation },
            };
            let _ = sender.send_blocking(panel_event);
            true
        });

        match self.manager.create_terminal(config, handler) {
            Ok(terminal_id) => {
                self.terminal_id = Some(terminal_id);
                self.launch_error = None;
                self.flush_pending_command(cx);
            }
            Err(error) => {
                // 启动失败要保留原始原因，画布上给出与 macOS 一致的居中提示，
                // 而不是只留一行底部状态。
                let message = error.to_string();
                self.launch_error = Some(SharedString::from(message.clone()));
                self.set_error(format!("{}: {message}", tr("Terminal unavailable")), cx);
            }
        }
        cx.notify();
    }

    fn handle_event(&mut self, event: PanelEvent, cx: &mut Context<Self>) {
        match event {
            PanelEvent::Output { generation, data } => {
                // 重启会先关掉旧 PTY；旧会话残留的输出不能写进新屏幕。
                if self.is_stale_generation(generation) {
                    return;
                }
                self.queue_output(&data, cx);
            }
            PanelEvent::Input(bytes) => {
                if let Some(id) = &self.terminal_id {
                    let _ = self.manager.write_to_terminal(
                        id,
                        TerminalInput::Binary { data: bytes },
                    );
                }
            }
            PanelEvent::Resize { rows, cols } => {
                if self.model.resize(cols as usize, rows as usize) {
                    if let Some(id) = &self.terminal_id {
                        let _ = self.manager.resize_terminal(
                            id,
                            TerminalSize {
                                rows,
                                cols,
                                pixel_width: 0,
                                pixel_height: 0,
                            },
                        );
                    }
                    cx.notify();
                }
            }
            PanelEvent::Scroll(delta) => {
                self.model.scroll(delta);
                cx.notify();
            }
            PanelEvent::Exit {
                generation,
                exit_code,
                signal,
            } => {
                // 重启后旧会话的退出事件已无对应代次，直接丢弃，避免清空新会话。
                if self.is_stale_generation(generation) {
                    return;
                }
                // 退出码之前到达的输出必须完整写入，不能被合批窗口吞掉。
                self.flush_output(cx);
                self.saw_exit = true;
                let message = match (exit_code, signal) {
                    (Some(code), _) => {
                        format!("{} ({}: {code})", tr("Terminal closed"), tr("exit code"))
                    }
                    (None, Some(sig)) => {
                        format!("{} ({}: {sig})", tr("Terminal closed"), tr("signal"))
                    }
                    _ => tr("Terminal closed").to_string(),
                };
                self.status = Some(StatusLine {
                    message: SharedString::from(message),
                    is_error: exit_code.is_some_and(|code| code != 0),
                });
                self.terminal_id = None;
                cx.notify();
            }
            PanelEvent::Closed { generation } => {
                // 同上：忽略来自已关闭旧会话的迟到事件。
                if self.is_stale_generation(generation) {
                    return;
                }
                self.flush_output(cx);
                if !self.saw_exit {
                    self.status = Some(StatusLine {
                        message: tr("Terminal closed").into(),
                        is_error: false,
                    });
                }
                self.terminal_id = None;
                cx.notify();
            }
            PanelEvent::TerminalError(error) => {
                self.set_error(error, cx);
            }
        }
    }

    /// 判断事件是否来自已被替换的旧会话。
    ///
    /// `start_terminal` 每建立一次 PTY 就把 `session_generation` 加一，事件在
    /// 创建时记下当时的代次；重启后旧会话的退出、关闭和残留输出都会因为代次
    /// 落后而被丢弃：前者能避免把新会话的 `terminal_id` 清掉，后者能避免旧
    /// 输出写进已经清空的屏幕。
    fn is_stale_generation(&self, generation: u64) -> bool {
        generation != self.session_generation
    }

    fn set_error(&mut self, error: impl Into<SharedString>, cx: &mut Context<Self>) {
        self.status = Some(StatusLine {
            message: error.into(),
            is_error: true,
        });
        cx.notify();
    }

    fn render_status_bar(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let status = self.status.as_ref()?;
        let tokens = current_tokens(cx);
        let color = if status.is_error {
            tokens.error
        } else {
            tokens.secondary_text
        };
        Some(
            div()
                .h(px(24.0))
                .flex_shrink_0()
                .px(px(8.0))
                .flex()
                .items_center()
                .bg(tokens.window)
                .border_b_1()
                .border_color(tokens.divider)
                .text_size(px(11.0))
                .text_color(color)
                .child(status.message.clone())
                .into_any_element(),
        )
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
        self.ensure_started(window, cx);

        let tokens = current_tokens(cx);
        let dark = tokens.editor.l < 0.5;
        let is_focused = self.focus_handle.is_focused(window);

        let mut root = div().flex().flex_col().size_full().bg(tokens.editor);

        // 启动失败时只用画布上的居中提示，不再叠加底部状态条（macOS 同样
        // 只有覆盖层，避免同一错误出现两次）。
        if self.launch_error.is_none() {
            if let Some(status_bar) = self.render_status_bar(cx) {
                root = root.child(status_bar);
            }
        }

        let content = view::render_terminal_surface(
            &self.model,
            &self.focus_handle,
            self.terminal_font_size,
            &tokens,
            dark,
            is_focused,
            self.resize_sender.clone(),
            self.key_sender.clone(),
            self.scroll_sender.clone(),
            self.close_handler.clone(),
            cx,
        );

        let mut area = div()
            .relative()
            .flex_1()
            .min_h(px(0.0))
            .child(content);
        // 启动失败时在画布上居中提示，对齐 macOS `TerminalSurfaceView`
        // 的 launchError 覆盖层：标题 + 原始错误 + 可执行的下一步。
        if let Some(error) = self.launch_error.clone() {
            area = area.child(render_launch_error(error, &tokens));
        }

        root.child(area)
    }
}

/// 终端启动失败的居中覆盖层。
fn render_launch_error(error: SharedString, tokens: &LitheTokens) -> AnyElement {
    div()
        .absolute()
        .inset_0()
        .flex()
        .items_center()
        .justify_center()
        .p(px(20.0))
        .child(
            v_flex()
                .max_w(px(420.0))
                .gap(px(8.0))
                .items_center()
                .child(
                    div()
                        .text_size(px(LitheMetrics::UI_FONT_SIZE))
                        .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                        .text_color(tokens.primary_text)
                        .child(tr("Unable to start terminal")),
                )
                .child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(error),
                )
                .child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.tertiary_text)
                        .child(tr(
                            "Detect installed shells and choose a shell from the New Terminal menu.",
                        )),
                ),
        )
        .into_any_element()
}
