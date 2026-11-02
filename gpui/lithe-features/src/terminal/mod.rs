//! 纯原生 GPUI 终端面板。
//!
//! 基于 `alacritty_terminal` 的 VT 状态机与 `lithe-terminal` 的 PTY 管理器，
//! 完全采用 GPUI 原生画布与文字系统进行渲染，不再依赖任何 WebView 或 xterm.js。

pub mod color;
pub mod keys;
pub mod model;
pub mod view;

use std::path::PathBuf;
use std::sync::Arc;

use gpui_kit::{
    AnyElement, AppContext as _, Context, FocusHandle, IntoElement, ParentElement, Render,
    SharedString, Styled, Window, div, px,
};
use lithe_terminal::{
    TerminalConfig, TerminalEvent, TerminalEventHandler, TerminalInput, TerminalManager,
    TerminalSize,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, current_tokens};

use self::model::TerminalModel;

/// 初始 PTY 尺寸。
const DEFAULT_ROWS: u16 = 24;
const DEFAULT_COLS: u16 = 80;
/// 默认回滚行数。
const DEFAULT_SCROLLBACK: u32 = 5000;

/// 内部事件流消息。
enum PanelEvent {
    /// PTY 输出字节。
    Output(Vec<u8>),
    /// PTY 错误。
    TerminalError(String),
    /// 子进程退出。
    Exit {
        exit_code: Option<u32>,
        signal: Option<String>,
    },
    /// PTY 关闭。
    Closed,
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
        if let Some(id) = self.terminal_id.take() {
            let _ = self.manager.close_terminal(&id);
        }
        self.terminal_started = false;
        self.pending_command = None;
        self.saw_exit = false;
        self.status = None;
        self.model.clear();
        cx.notify();
    }

    /// 获取当前 shell。
    pub fn shell(&self) -> Option<&str> {
        self.shell.as_deref()
    }

    /// 切换工作区根目录。
    pub fn set_root(&mut self, root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        if let Some(id) = self.terminal_id.take() {
            let _ = self.manager.close_terminal(&id);
        }
        self.root = root;
        self.terminal_started = false;
        self.saw_exit = false;
        self.status = None;
        self.pending_command = None;
        self.model.clear();
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

    /// 兼容接口：纯原生不再需要 WebView 隐藏 hack。
    pub fn set_webview_visible(&mut self, _visible: bool, _cx: &mut Context<Self>) {}

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
        let handler: TerminalEventHandler = Arc::new(move |_id, event| {
            let panel_event = match event {
                TerminalEvent::Output { data } => PanelEvent::Output(data),
                TerminalEvent::Error { message } => PanelEvent::TerminalError(message),
                TerminalEvent::Exit { exit_code, signal } => {
                    PanelEvent::Exit { exit_code, signal }
                }
                TerminalEvent::Closed => PanelEvent::Closed,
            };
            let _ = sender.send_blocking(panel_event);
            true
        });

        match self.manager.create_terminal(config, handler) {
            Ok(terminal_id) => {
                self.terminal_id = Some(terminal_id);
                self.flush_pending_command(cx);
            }
            Err(error) => {
                self.set_error(format!("{}: {error}", tr("Terminal unavailable")), cx);
            }
        }
        cx.notify();
    }

    fn handle_event(&mut self, event: PanelEvent, cx: &mut Context<Self>) {
        match event {
            PanelEvent::Output(bytes) => {
                self.model.process_bytes(&bytes);
                cx.notify();
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
            PanelEvent::Exit { exit_code, signal } => {
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
            PanelEvent::Closed => {
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

        if let Some(status_bar) = self.render_status_bar(cx) {
            root = root.child(status_bar);
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
            cx,
        );

        root.child(div().flex_1().min_h(px(0.0)).child(content))
    }
}
