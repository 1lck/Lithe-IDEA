use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AnyElement, AppContext as _, Context, Entity, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Window,
};

use crate::theme::ThemeColors;
use crate::workbench::terminal::TerminalView;

/// 运行历史上限。
const MAX_RUN_HISTORY: usize = 50;

/// Git 提交记录行数上限。
const MAX_GIT_LOG_ENTRIES: usize = 50;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BottomTab {
    Terminal,
    Run,
    Diagnostics,
    GitLog,
}

/// Git 提交记录的一行：短 hash + 首行 message，只读展示不跳转。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitLogEntry {
    pub hash: String,
    pub message: String,
}

pub struct BottomPanelView {
    pub active_tab: BottomTab,
    pub is_collapsed: bool,
    pub height: f32,
    pub terminal: Entity<TerminalView>,
    pub diagnostics: Vec<String>,
    /// 终端工作目录；GitLog 面板取数时作为 `git -C` 目标。
    pub working_dir: String,
    /// 运行历史（`TerminalView::send_command` 被调用时由宿主经
    /// [`BottomPanelView::record_run`] 落入），上限 [`MAX_RUN_HISTORY`]。
    pub run_history: Vec<String>,
    /// 最近一次加载的 Git 提交记录。
    pub git_log: Vec<GitLogEntry>,
    /// Git 记录加载失败时的展示文案；成功后清空。
    pub git_log_error: Option<String>,
}

impl BottomPanelView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let terminal = cx.new(|cx| TerminalView::new(working_dir.clone(), cx));

        Self {
            active_tab: BottomTab::Terminal,
            is_collapsed: true,
            height: 240.0,
            terminal,
            diagnostics: Vec::new(),
            working_dir,
            run_history: Vec::new(),
            git_log: Vec::new(),
            git_log_error: None,
        }
    }

    pub fn is_visible(&self) -> bool {
        !self.is_collapsed
    }

    pub fn set_height(&mut self, height: f32, cx: &mut Context<Self>) {
        self.height = height;
        cx.notify();
    }

    pub fn set_tab(&mut self, tab: BottomTab, cx: &mut Context<Self>) {
        self.active_tab = tab;
        self.is_collapsed = false;
        if tab == BottomTab::GitLog {
            // 打开即刷新提交记录；refresh_git_log 内已 notify。
            self.refresh_git_log(cx);
            return;
        }
        cx.notify();
    }

    pub fn toggle_collapsed(&mut self, cx: &mut Context<Self>) {
        self.is_collapsed = !self.is_collapsed;
        cx.notify();
    }

    /// 记录一次运行命令；空命令忽略，超出上限丢弃最旧记录。
    /// 宿主在转调 `TerminalView::send_command` 时调用。
    pub fn record_run(&mut self, cmd: &str, cx: &mut Context<Self>) {
        let cmd = cmd.trim();
        if cmd.is_empty() {
            return;
        }
        self.run_history.push(cmd.to_string());
        if self.run_history.len() > MAX_RUN_HISTORY {
            let overflow = self.run_history.len() - MAX_RUN_HISTORY;
            self.run_history.drain(..overflow);
        }
        cx.notify();
    }

    /// 是否有运行历史；宿主据此决定左侧栏是否展示 maven 项。
    pub fn has_run_history(&self) -> bool {
        !self.run_history.is_empty()
    }

    /// 重新加载 Git 提交记录。core 的 `git.historyPage` 需经宿主异步接线，
    /// 这里用 `git -C <working_dir> log --oneline -50` 同步退化实现，
    /// 解析 hash + 首行 message 只读展示。
    pub fn refresh_git_log(&mut self, cx: &mut Context<Self>) {
        match load_git_log(&self.working_dir) {
            Ok(entries) => {
                self.git_log = entries;
                self.git_log_error = None;
            }
            Err(err) => {
                self.git_log.clear();
                self.git_log_error = Some(err);
            }
        }
        cx.notify();
    }

    /// 占位日志入口：Tauri 没有通用 Output 面板，各业务接线后改走各自面板，
    /// 当前仅保留调用点可编译，不存储不展示。
    pub fn append_log(&mut self, _log: String, _cx: &mut Context<Self>) {}

    fn render_tab_button(
        &self,
        id: &'static str,
        icon: IconName,
        label: String,
        is_active: bool,
        tab: BottomTab,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        h_flex()
            .id(id)
            .items_center()
            .gap_1p5()
            .px_3()
            .h(px(30.0))
            .cursor_pointer()
            .text_xs()
            .when(is_active, |btn| {
                btn.bg(ThemeColors::bg_bottom_panel())
                    .text_color(ThemeColors::text_primary())
                    .border_b_2()
                    .border_color(ThemeColors::accent_blue())
            })
            .when(!is_active, |btn| {
                btn.text_color(ThemeColors::text_muted()).hover(|h| {
                    h.bg(ThemeColors::bg_tab_hover())
                        .text_color(ThemeColors::text_primary())
                })
            })
            .child(Icon::new(icon).size(px(13.0)).text_color(if is_active {
                ThemeColors::accent_blue()
            } else {
                ThemeColors::text_muted()
            }))
            .child(label)
            .on_click(cx.listener(move |this, _event, _window, cx| {
                this.set_tab(tab, cx);
            }))
    }

    /// Run 面板：运行历史列表，每行重跑按钮经 terminal 重放命令。
    fn render_run_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.run_history.is_empty() {
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(ThemeColors::text_muted())
                .child(run_empty_text(cx))
                .into_any_element();
        }

        let rows: Vec<AnyElement> = self
            .run_history
            .iter()
            .enumerate()
            .map(|(idx, cmd)| {
                let rerun = cmd.clone();
                h_flex()
                    .id(format!("run-history-{idx}"))
                    .h(px(26.0))
                    .w_full()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .rounded_sm()
                    .text_xs()
                    .text_color(ThemeColors::text_primary())
                    .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
                    .child(
                        div()
                            .flex_1()
                            .truncate()
                            .font_family("monospace")
                            .child(cmd.clone()),
                    )
                    .child(
                        Button::new(format!("run-rerun-{idx}"))
                            .small()
                            .ghost()
                            .icon(IconName::Play)
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                let _ =
                                    this.terminal.update(cx, |t, cx| t.send_command(&rerun, cx));
                            })),
                    )
                    .into_any_element()
            })
            .collect();

        div()
            .flex_1()
            .w_full()
            .overflow_y_scrollbar()
            .py_1()
            .children(rows)
            .into_any_element()
    }

    /// GitLog 面板：只读提交列表，行点击不跳转；空态与失败文案兜底。
    fn render_git_log_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        if let Some(err) = self.git_log_error.clone() {
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(ThemeColors::text_muted())
                .child(if err.is_empty() {
                    git_log_failed_text(cx).to_string()
                } else {
                    err
                })
                .into_any_element();
        }
        if self.git_log.is_empty() {
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(ThemeColors::text_muted())
                .child(git_log_empty_text(cx))
                .into_any_element();
        }

        let rows: Vec<AnyElement> = self
            .git_log
            .iter()
            .enumerate()
            .map(|(idx, entry)| {
                h_flex()
                    .id(format!("git-log-{idx}"))
                    .w_full()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_1()
                    .text_xs()
                    .child(
                        div()
                            .flex_shrink_0()
                            .font_family("monospace")
                            .text_color(ThemeColors::accent_blue())
                            .child(entry.hash.clone()),
                    )
                    .child(
                        div()
                            .flex_1()
                            .truncate()
                            .text_color(ThemeColors::text_primary())
                            .child(entry.message.clone()),
                    )
                    .into_any_element()
            })
            .collect();

        div()
            .flex_1()
            .w_full()
            .overflow_y_scrollbar()
            .py_1()
            .children(rows)
            .into_any_element()
    }
}

impl Render for BottomPanelView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.is_collapsed {
            return div().h(px(0.0));
        }

        v_flex()
            .h(px(self.height))
            .w_full()
            .bg(ThemeColors::bg_bottom_panel())
            .border_t_1()
            .border_color(ThemeColors::border())
            .child(
                // 顶部 Tab 切换栏（高 30px）：仅保留 Tauri 存在的 Terminal / Diagnostics，
                // 自创的 Output 页签已去掉。
                h_flex()
                    .h(px(30.0))
                    .w_full()
                    .bg(ThemeColors::bg_tab_bar())
                    .border_b_1()
                    .border_color(ThemeColors::border())
                    .items_center()
                    .justify_between()
                    .px_2()
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(self.render_tab_button(
                                "tab-terminal",
                                IconName::Terminal,
                                crate::i18n::menu_text(cx, "workbench.terminal").to_string(),
                                self.active_tab == BottomTab::Terminal,
                                BottomTab::Terminal,
                                cx,
                            ))
                            .child(self.render_tab_button(
                                "tab-run",
                                IconName::Play,
                                crate::i18n::menu_text(cx, "workbench.run").to_string(),
                                self.active_tab == BottomTab::Run,
                                BottomTab::Run,
                                cx,
                            ))
                            .child(self.render_tab_button(
                                "tab-diagnostics",
                                IconName::TriangleAlert,
                                format!(
                                    "{} ({})",
                                    crate::i18n::menu_text(cx, "workbench.diagnostics"),
                                    self.diagnostics.len()
                                ),
                                self.active_tab == BottomTab::Diagnostics,
                                BottomTab::Diagnostics,
                                cx,
                            ))
                            .child(self.render_tab_button(
                                "tab-gitlog",
                                IconName::GitGraph,
                                crate::i18n::menu_text(cx, "workbench.gitLog").to_string(),
                                self.active_tab == BottomTab::GitLog,
                                BottomTab::GitLog,
                                cx,
                            )),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .gap_1()
                            .child(
                                Button::new("clear-panel")
                                    .small()
                                    .ghost()
                                    .icon(IconName::Trash)
                                    .tooltip(crate::i18n::menu_text(cx, "ui.clear"))
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        match this.active_tab {
                                            BottomTab::Terminal => {
                                                let _ =
                                                    this.terminal.update(cx, |t, cx| t.clear(cx));
                                            }
                                            BottomTab::Run => {
                                                this.run_history.clear();
                                                cx.notify();
                                            }
                                            BottomTab::Diagnostics => {
                                                this.diagnostics.clear();
                                                cx.notify();
                                            }
                                            // GitLog 无可清空的输出，该按钮退化为手动刷新。
                                            BottomTab::GitLog => {
                                                this.refresh_git_log(cx);
                                            }
                                        }
                                    })),
                            )
                            .child(
                                Button::new("collapse-panel")
                                    .small()
                                    .ghost()
                                    .icon(IconName::ChevronDown)
                                    .tooltip(crate::i18n::menu_text(cx, "ui.close"))
                                    .on_click(cx.listener(|this, _event, _window, cx| {
                                        this.toggle_collapsed(cx);
                                    })),
                            ),
                    ),
            )
            .child(
                // 内容区域根据 Tab 切换
                div().flex_1().w_full().child(match self.active_tab {
                    BottomTab::Terminal => div()
                        .size_full()
                        .child(self.terminal.clone())
                        .into_any_element(),
                    BottomTab::Run => self.render_run_panel(cx),
                    BottomTab::Diagnostics => div()
                        .size_full()
                        .p_3()
                        .overflow_y_scrollbar()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(if self.diagnostics.is_empty() {
                            crate::i18n::menu_text(cx, "diagnostics.empty").to_string()
                        } else {
                            format!(
                                "{} ({})",
                                crate::i18n::menu_text(cx, "workbench.diagnostics"),
                                self.diagnostics.len()
                            )
                        })
                        .into_any_element(),
                    BottomTab::GitLog => self.render_git_log_panel(cx),
                }),
            )
    }
}

/// 同步取 Git 提交记录：`git -C <workdir> log --oneline -N`，解析 hash + 首行
/// message。core 侧 `git.historyPage` 存在但 linux `CoreClient` 尚未暴露对应
/// 方法，且本次只允许改动底部面板/活动栏两文件，故先用子进程退化实现；
/// 宿主后续可把 [`BottomPanelView::refresh_git_log`] 切到 core 异步接线。
fn load_git_log(workdir: &str) -> Result<Vec<GitLogEntry>, String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(workdir)
        .arg("log")
        .arg("--oneline")
        .arg(format!("-{MAX_GIT_LOG_ENTRIES}"))
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(stderr);
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let entries = stdout
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() {
                return None;
            }
            let (hash, message) = match line.split_once(char::is_whitespace) {
                Some((hash, message)) => (hash.trim(), message.trim()),
                None => (line, ""),
            };
            if hash.is_empty() {
                return None;
            }
            Some(GitLogEntry {
                hash: hash.to_string(),
                message: message.to_string(),
            })
        })
        .collect();
    Ok(entries)
}

fn run_empty_text(cx: &gpui_kit::App) -> &'static str {
    if crate::i18n::is_zh(cx) {
        "暂无运行历史"
    } else {
        "No run history"
    }
}

fn git_log_empty_text(cx: &gpui_kit::App) -> &'static str {
    if crate::i18n::is_zh(cx) {
        "暂无提交记录"
    } else {
        "No commits"
    }
}

fn git_log_failed_text(cx: &gpui_kit::App) -> &'static str {
    if crate::i18n::is_zh(cx) {
        "加载提交记录失败"
    } else {
        "Failed to load git log"
    }
}
