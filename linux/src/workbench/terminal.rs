use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Sizable as _};
use gpui_kit::{
    div, px, AppContext as _, Context, Entity, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, Styled as _, Subscription, Window,
};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::{Read, Write};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;

use crate::settings;
use crate::theme::ThemeColors;

/// 输出行数上限。
const MAX_TERMINAL_LINES: usize = 1000;

/// 未换行缓冲上限（字符），超出保留末尾，避免无换物流撑爆内存。
const MAX_PENDING_CHARS: usize = 8192;
const PENDING_KEEP_CHARS: usize = 4096;

/// 剥离 ANSI 转义序列与无用控制字符（保留 `\n` `\r` `\t` 交由换行逻辑处理）。
/// 无 xterm 网格，按纯文本展示是既定适配（右键菜单/复制等同理缺失）。
fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            match chars.peek() {
                // CSI：`ESC [` … 最终字节 `@`..=`~`
                Some('[') => {
                    chars.next();
                    loop {
                        match chars.next() {
                            None => break,
                            Some(c) if ('@'..='~').contains(&c) => break,
                            Some(_) => {}
                        }
                    }
                }
                // OSC：`ESC ]` … 以 BEL 或 `ESC \` 结束
                Some(']') => {
                    chars.next();
                    let mut prev_esc = false;
                    loop {
                        match chars.next() {
                            None => break,
                            Some('\x07') => break,
                            Some('\x1b') => prev_esc = true,
                            Some('\\') if prev_esc => break,
                            Some(_) => prev_esc = false,
                        }
                    }
                }
                // 字符集选择等两字符序列
                Some('(') | Some(')') | Some('#') => {
                    chars.next();
                    chars.next();
                }
                Some(_) => {
                    chars.next();
                }
                None => {}
            }
        } else if ch.is_control() && ch != '\n' && ch != '\r' && ch != '\t' {
            // 丢弃 BEL 等无用控制字符
        } else {
            out.push(ch);
        }
    }
    out
}

/// Linux 原生 PTY 会话
pub struct TerminalSession {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    pub output_lines: Arc<Mutex<Vec<String>>>,
    #[allow(dead_code)]
    input_buffer: Arc<Mutex<String>>,
}

impl TerminalSession {
    /// 打开 PTY 会话并起输出线程：线程只透传原始字节块，主线程泵负责
    /// 解析换行/回车并 `notify`（输出实时出现，对齐 xterm 的流式展示）。
    /// 返回会话与输出 channel；`banner` 为首行提示（调用方按语言构造）。
    pub fn new(
        cols: u16,
        rows: u16,
        working_dir: &str,
        shell: &str,
        banner: Option<String>,
    ) -> anyhow::Result<(Self, mpsc::Receiver<String>)> {
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

        let output_lines = Arc::new(Mutex::new(
            banner.map(|line| vec![line]).unwrap_or_default(),
        ));
        let (tx, rx) = mpsc::channel::<String>();

        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let chunk = String::from_utf8_lossy(&buf[..n]).into_owned();
                        if tx.send(chunk).is_err() {
                            break;
                        }
                    }
                }
            }
        });

        Ok((
            Self {
                writer: Arc::new(Mutex::new(writer)),
                output_lines,
                input_buffer: Arc::new(Mutex::new(String::new())),
            },
            rx,
        ))
    }

    pub fn write_input(&self, input: &str) -> anyhow::Result<()> {
        let mut writer = self.writer.lock().unwrap();
        writer.write_all(input.as_bytes())?;
        writer.flush()?;
        Ok(())
    }

    pub fn get_lines(&self) -> Vec<String> {
        self.output_lines.lock().unwrap().clone()
    }
}

/// 终端视图组件：输出区 + 可输入的命令行（回车/按钮发送整行）。
pub struct TerminalView {
    pub session: Option<TerminalSession>,
    pub working_dir: String,
    /// 未换行缓冲：跨字节块累积，`\r` 覆盖当前行内容。
    pending: String,
    input: Option<Entity<InputState>>,
    _input_subscription: Option<Subscription>,
    /// 回车发送后待清空输入框（render 内有 `window` 才可执行）。
    clear_pending: bool,
}

impl TerminalView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            session: None,
            working_dir,
            pending: String::new(),
            input: None,
            _input_subscription: None,
            clear_pending: false,
        };
        view.attach_session(cx);
        view
    }

    /// 打开 PTY 会话并起主线程输出泵（channel 收字节块 → 解析落行 → notify）。
    fn attach_session(&mut self, cx: &mut Context<Self>) {
        let banner = crate::i18n::menu_text(cx, "terminal.session")
            .replace("{shell}", &Self::resolve_shell(cx));
        match TerminalSession::new(
            120,
            30,
            &self.working_dir,
            &Self::resolve_shell(cx),
            Some(banner),
        ) {
            Ok((session, rx)) => {
                self.session = Some(session);
                self.pending.clear();
                Self::spawn_pump(rx, cx);
            }
            Err(_) => {
                self.session = None;
            }
        }
        cx.notify();
    }

    /// 主线程输出泵：后台收字节块，回主线程解析。
    fn spawn_pump(rx: mpsc::Receiver<String>, cx: &mut Context<Self>) {
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
                Some(chunk) => {
                    if this
                        .update(cx, |view, cx| {
                            view.push_chunk(&chunk);
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

    /// 解析输出块：ANSI 剥离后按换行落行、`\r` 覆盖当前行。
    fn push_chunk(&mut self, chunk: &str) {
        let text = strip_ansi(chunk);
        let Some(session) = self.session.as_ref() else {
            return;
        };
        let Ok(mut lines) = session.output_lines.lock() else {
            return;
        };
        for piece in text.split_inclusive('\n') {
            let (content, newline) = match piece.strip_suffix('\n') {
                Some(content) => (content, true),
                None => (piece, false),
            };
            // `\r` 语义为回车覆盖：只保留最后一个 `\r` 之后的内容。
            let visible = content.rsplit('\r').next().unwrap_or("");
            self.pending.push_str(visible);
            let count = self.pending.chars().count();
            if count > MAX_PENDING_CHARS {
                let skip = count - PENDING_KEEP_CHARS;
                self.pending = self.pending.chars().skip(skip).collect();
            }
            if newline {
                lines.push(std::mem::take(&mut self.pending));
                if lines.len() > MAX_TERMINAL_LINES {
                    lines.remove(0);
                }
            }
        }
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

    pub fn send_command(&mut self, cmd: &str, cx: &mut Context<Self>) {
        if let Some(session) = &self.session {
            let mut full = cmd.to_string();
            full.push('\n');
            let _ = session.write_input(&full);
        }
        cx.notify();
    }

    pub fn clear(&mut self, cx: &mut Context<Self>) {
        if let Some(session) = &self.session {
            if let Ok(mut lines) = session.output_lines.lock() {
                lines.clear();
                lines.push(crate::i18n::menu_text(cx, "terminal.cleared").to_string());
            }
        }
        self.pending.clear();
        cx.notify();
    }

    /// 用现有工作目录重建 PTY 会话（失败则置空并通知）。
    pub fn respawn(&mut self, cx: &mut Context<Self>) {
        self.session = None;
        self.attach_session(cx);
    }

    /// 懒创建命令行输入框。
    fn ensure_input(
        slot: &mut Option<Entity<InputState>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        if let Some(entity) = slot.clone() {
            return entity;
        }
        let entity = cx.new(|cx| InputState::new(window, cx));
        *slot = Some(entity.clone());
        entity
    }
}

impl Render for TerminalView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 命令行输入框懒创建；回车发送整行（`PressEnter`），发送后在本次
        // render 内清空（`set_value` 需 `window`，订阅回调里拿不到）。
        let input_entity = Self::ensure_input(&mut self.input, window, cx);
        if self._input_subscription.is_none() {
            let entity = input_entity.clone();
            self._input_subscription = Some(cx.subscribe(
                &input_entity,
                move |this: &mut Self, _, event: &InputEvent, cx| {
                    if matches!(event, InputEvent::PressEnter { .. }) {
                        let cmd = entity.read(cx).value().to_string();
                        if !cmd.trim().is_empty() {
                            this.send_command(&cmd, cx);
                            this.clear_pending = true;
                            cx.notify();
                        }
                    }
                },
            ));
        }
        if self.clear_pending {
            self.clear_pending = false;
            let entity = input_entity.clone();
            entity.update(cx, |state, cx| {
                state.set_value("", window, cx);
            });
        }

        let mut lines = self
            .session
            .as_ref()
            .map(|s| s.get_lines())
            .unwrap_or_else(
                || vec![crate::i18n::menu_text(cx, "terminal.unavailable").to_string()],
            );
        if self.session.is_some() && !self.pending.is_empty() {
            lines.push(self.pending.clone());
        }

        v_flex()
            .size_full()
            // 终端区背景跟随主题（对齐 Tauri xterm 的 `--background`），
            // 浅色主题下不再残留深色底。
            .bg(ThemeColors::background())
            .child(
                // 终端输出行展示区（控制栏由底部窗格头负责，不再自带）。
                div()
                    .flex_1()
                    .w_full()
                    .min_h_0()
                    .overflow_y_scrollbar()
                    .p_2()
                    .text_xs()
                    .text_size(px(crate::settings::get(cx).terminal_font_size))
                    .text_color(ThemeColors::foreground())
                    .font_family("monospace")
                    .children(lines.into_iter().enumerate().map(|(idx, line)| {
                        div().id(idx).child(if line.is_empty() {
                            " ".to_string()
                        } else {
                            line
                        })
                    })),
            )
            .child(
                // 命令行输入条：可输入单行命令，回车或按钮发送。
                h_flex()
                    .h(px(32.0))
                    .w_full()
                    .flex_shrink_0()
                    .bg(ThemeColors::surface())
                    .border_t_1()
                    .border_color(ThemeColors::border())
                    .items_center()
                    .px_2()
                    .gap_2()
                    .child(
                        div()
                            .text_xs()
                            .text_color(ThemeColors::success())
                            .font_family("monospace")
                            .child("$"),
                    )
                    .child(
                        div()
                            .flex_1()
                            .child(Input::new(&input_entity).cleanable(true)),
                    )
                    .child(
                        Button::new("run-cmd")
                            .small()
                            .primary()
                            .label(crate::i18n::menu_text(cx, "terminal.execute"))
                            .on_click(cx.listener(move |_this, _event, window, cx| {
                                let cmd = input_entity.read(cx).value().to_string();
                                if !cmd.trim().is_empty() {
                                    let _ = _this.session.as_ref().map(|session| {
                                        let mut full = cmd.clone();
                                        full.push('\n');
                                        let _ = session.write_input(&full);
                                    });
                                    input_entity.update(cx, |state, cx| {
                                        state.set_value("", window, cx);
                                    });
                                    cx.notify();
                                }
                            })),
                    ),
            )
    }
}
