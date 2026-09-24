use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Sizable as _};
use gpui_kit::{
    div, px, Context, InteractiveElement as _, IntoElement, ParentElement as _, Render,
    Styled as _, Window,
};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::settings;
use crate::theme::ThemeColors;

/// Linux 原生 PTY 会话
pub struct TerminalSession {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    pub output_lines: Arc<Mutex<Vec<String>>>,
    #[allow(dead_code)]
    input_buffer: Arc<Mutex<String>>,
}

impl TerminalSession {
    pub fn new(cols: u16, rows: u16, working_dir: &str, shell: &str) -> anyhow::Result<Self> {
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

        let output_lines = Arc::new(Mutex::new(vec![format!(
            "Lithe Terminal (PTY Session: {shell})"
        )]));
        let output_lines_clone = Arc::clone(&output_lines);

        thread::spawn(move || {
            let mut buf = [0u8; 1024];
            let mut line_accumulator = String::new();

            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                let chunk = String::from_utf8_lossy(&buf[..n]);
                for ch in chunk.chars() {
                    if ch == '\n' {
                        let mut lines = output_lines_clone.lock().unwrap();
                        lines.push(line_accumulator.clone());
                        if lines.len() > 1000 {
                            lines.remove(0);
                        }
                        line_accumulator.clear();
                    } else if ch == '\r' {
                        // ignore carriage return
                    } else {
                        line_accumulator.push(ch);
                    }
                }
                if !line_accumulator.is_empty() {
                    let mut lines = output_lines_clone.lock().unwrap();
                    if let Some(last) = lines.last_mut() {
                        *last = line_accumulator.clone();
                    }
                }
            }
        });

        Ok(Self {
            writer: Arc::new(Mutex::new(writer)),
            output_lines,
            input_buffer: Arc::new(Mutex::new(String::new())),
        })
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

/// 终端视图组件
pub struct TerminalView {
    pub session: Option<TerminalSession>,
    pub current_input: String,
    pub working_dir: String,
}

impl TerminalView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let session = TerminalSession::new(120, 30, &working_dir, &Self::resolve_shell(cx)).ok();

        Self {
            session,
            current_input: String::new(),
            working_dir,
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
        self.current_input.clear();
        cx.notify();
    }

    pub fn clear(&mut self, cx: &mut Context<Self>) {
        if let Some(session) = &self.session {
            if let Ok(mut lines) = session.output_lines.lock() {
                lines.clear();
                lines.push("Terminal cleared.".to_string());
            }
        }
        cx.notify();
    }

    /// 用现有工作目录重建 PTY 会话（失败则置空并通知）。
    pub fn respawn(&mut self, cx: &mut Context<Self>) {
        self.session =
            TerminalSession::new(120, 30, &self.working_dir, &Self::resolve_shell(cx)).ok();
        cx.notify();
    }
}

impl Render for TerminalView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lines = self
            .session
            .as_ref()
            .map(|s| s.get_lines())
            .unwrap_or_else(|| vec!["PTY unavailable".to_string()]);

        v_flex()
            .size_full()
            // 终端区背景跟随主题（对齐 Tauri xterm 的 `--background`），
            // 浅色主题下不再残留深色底。
            .bg(ThemeColors::background())
            .p_2()
            .child(
                // 终端顶部控制栏
                h_flex()
                    .h(px(28.0))
                    .w_full()
                    .justify_between()
                    .items_center()
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .pb_1()
                    .child(
                        h_flex()
                            .items_center()
                            .gap_2()
                            .text_xs()
                            .text_color(ThemeColors::subtle_foreground())
                            .child("Linux PTY Shell")
                            .child(format!("({})", self.working_dir)),
                    )
                    .child(
                        Button::new("clear-term")
                            .small()
                            .ghost()
                            .label(crate::i18n::menu_text(cx, "ui.clear"))
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                this.clear(cx);
                            })),
                    ),
            )
            .child(
                // 终端输出行展示区
                div()
                    .flex_1()
                    .w_full()
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
                // 命令行输入条
                h_flex()
                    .h(px(32.0))
                    .w_full()
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
                            .text_xs()
                            .text_color(ThemeColors::foreground())
                            .font_family("monospace")
                            .child(if self.current_input.is_empty() {
                                "Type command here...".to_string()
                            } else {
                                self.current_input.clone()
                            }),
                    )
                    .child(
                        Button::new("run-cmd")
                            .small()
                            .primary()
                            .label("Execute")
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                let cmd = this.current_input.clone();
                                if !cmd.is_empty() {
                                    this.send_command(&cmd, cx);
                                }
                            })),
                    ),
            )
    }
}
