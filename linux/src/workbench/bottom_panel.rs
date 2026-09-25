use std::sync::{mpsc, Arc, Mutex};

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::EventEmitter;
use gpui_kit::{
    div, px, AnyElement, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, ScrollHandle, StatefulInteractiveElement as _,
    Styled as _, Window,
};

use crate::core::CoreClient;
use crate::theme::ThemeColors;
use crate::workbench::terminal::TerminalView;

/// 运行历史上限。
const MAX_RUN_HISTORY: usize = 50;

/// Run 输出保留上限（行），超出丢弃最旧。
const MAX_RUN_OUTPUT: usize = 2000;

/// Run 面板工程状态，对齐 Tauri RunPane 的 missing/ready/invalid 三态
/// （Linux 可用子集：invalid 统一为 `Failed` 并携带 core 错误文案）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunProjectState {
    /// 无可运行配置（非 Java/Maven/npm 工程或配置为空）。
    Missing,
    /// 正在经 core 探测工程与配置。
    Loading,
    /// 配置列表可用。
    Ready,
    /// 探测失败，内附展示文案。
    Failed(String),
}

/// Run 配置行：本地 `.lithe/run/configurations.json` 与
/// `runConfig.generate` 结果的显示子集。
#[derive(Debug, Clone)]
pub struct RunConfigItem {
    /// core 配置 id（本地文件项用配置名代替；`createLaunchPlan`
    /// 可能因此找不到而走退化执行）。
    pub id: String,
    pub name: String,
    /// `mainClass`（java）|`maven`|`npm`。
    pub kind: String,
    /// 副标题：主类 / 模块 / 脚本参数。
    pub detail: String,
    pub main_class: Option<String>,
    /// java 源码路径（generate 结果的 `extensions.java.source`），单文件退化编译用。
    pub source: Option<String>,
}

/// 后台运行步骤（退化执行用，不经 core 常驻进程宿主）。
#[derive(Debug, Clone)]
struct RunStep {
    program: String,
    args: Vec<String>,
    cwd: String,
}

/// 进程 framing 行文案（`run_steps_blocking` 无 `cx`，调用方预取传入）。
#[derive(Debug, Clone)]
struct StepText {
    start_failed: String,
    exit_code: String,
    exited: String,
    finished: String,
}

impl StepText {
    fn load(cx: &gpui_kit::App) -> Self {
        Self {
            start_failed: crate::i18n::menu_text(cx, "run.startFailed").to_string(),
            exit_code: crate::i18n::menu_text(cx, "run.exitCode").to_string(),
            exited: crate::i18n::menu_text(cx, "run.exited").to_string(),
            finished: crate::i18n::menu_text(cx, "run.finished").to_string(),
        }
    }
}

/// 上次 Maven 目标参数（头部重跑按钮回放，对齐 Tauri `rerunLastTest` 语义的子集）。
#[derive(Debug, Clone)]
struct MavenGoalParams {
    pom_path: String,
    goal: String,
    target: String,
    profiles: Vec<String>,
    skip_tests: bool,
}

/// Git 提交记录行数上限。
const MAX_GIT_LOG_ENTRIES: usize = 50;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BottomTab {
    Terminal,
    Run,
    Maven,
    Diagnostics,
    GitLog,
}

/// 诊断面板中的一条问题，字段与 Tauri DiagnosticsBuffer 的展示模型对齐。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticEntry {
    pub severity: String,
    pub file_path: String,
    pub line: u32,
    pub column: u32,
    pub message: String,
    pub source: Option<String>,
    pub code: Option<String>,
}

/// 诊断面板向外发出的定位事件。
#[derive(Debug, Clone)]
pub enum BottomPanelEvent {
    OpenFile { path: String, line: u32 },
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
    pub diagnostics: Vec<DiagnosticEntry>,
    /// 终端工作目录；GitLog 面板取数时作为 `git -C` 目标。
    pub working_dir: String,
    /// 运行历史（`TerminalView::send_command` 被调用时由宿主经
    /// [`BottomPanelView::record_run`] 落入），上限 [`MAX_RUN_HISTORY`]。
    pub run_history: Vec<String>,
    /// Run 面板状态机（Tauri RunPane 的 Linux 可用子集）。
    pub(crate) run_state: RunProjectState,
    /// Run 面板工程展示名（工作区目录名）。
    pub(crate) run_project_name: String,
    /// Run 配置列表（本地文件优先，否则 generate 结果）。
    pub(crate) run_configs: Vec<RunConfigItem>,
    /// 选中的 Run 配置 id。
    pub(crate) selected_run_config: Option<String>,
    /// 运行输出行（后台线程经 channel 推送，`cx.spawn` 泵入）。
    pub(crate) run_output: Vec<String>,
    /// 是否有进程在跑。
    pub(crate) run_running: bool,
    /// 输出跟随末尾（对齐 Tauri `scrollOutputToEnd`，默认开，落盘持久化）。
    pub(crate) run_follow_end: bool,
    /// 运行输出滚动句柄（跟随末尾用）。
    run_scroll: ScrollHandle,
    /// 上次跟随到的输出行数（只在新增时滚动，避免无关重绘抢夺滚动条）。
    run_followed_len: usize,
    /// Maven 任务标题（对齐 Tauri `taskTitle`，如 `compile · pom.xml`）。
    pub(crate) maven_title: Option<String>,
    /// Maven 任务输出行（`$ mvn …` 开头，对齐 Tauri Maven 页）。
    pub(crate) maven_output: Vec<String>,
    /// Maven 任务是否在跑。
    pub(crate) maven_running: bool,
    /// core 客户端（`reload_run_project` / `createLaunchPlan` 经它走 core JSON 命令）。
    client: CoreClient,
    /// 在跑子进程句柄：停止按钮经 `kill` 停，运行线程经 `try_wait` 短锁轮询收割。
    run_child: Arc<Mutex<Option<std::process::Child>>>,
    /// Maven 任务子进程句柄（与 Run 共用停止语义，分开存放可各自启停）。
    maven_child: Arc<Mutex<Option<std::process::Child>>>,
    /// Maven 启动序号，丢弃过期 `launchPlan` 结果。
    maven_seq: u64,
    /// 上次 Maven 目标参数（头部重跑按钮回放）。
    last_maven_goal: Option<MavenGoalParams>,
    /// reload 序号，丢弃过期探测结果。
    run_seq: u64,
    /// 最近一次加载的 Git 提交记录。
    pub git_log: Vec<GitLogEntry>,
    /// Git 记录加载失败时的展示文案；成功后清空。
    pub git_log_error: Option<String>,
}

impl EventEmitter<BottomPanelEvent> for BottomPanelView {}

impl BottomPanelView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let terminal = cx.new(|cx| TerminalView::new(working_dir.clone(), cx));

        Self {
            active_tab: BottomTab::Terminal,
            is_collapsed: true,
            height: 240.0,
            terminal,
            diagnostics: Vec::new(),
            working_dir: working_dir.clone(),
            run_history: Vec::new(),
            run_state: RunProjectState::Missing,
            run_project_name: crate::settings::project_dir_name(&working_dir).to_string(),
            run_configs: Vec::new(),
            selected_run_config: None,
            run_output: Vec::new(),
            run_running: false,
            run_follow_end: crate::settings::get(cx).run_scroll_to_end,
            run_scroll: ScrollHandle::new(),
            run_followed_len: 0,
            maven_title: None,
            maven_output: Vec::new(),
            maven_running: false,
            maven_child: Arc::new(Mutex::new(None)),
            maven_seq: 0,
            last_maven_goal: None,
            client: CoreClient::new(),
            run_child: Arc::new(Mutex::new(None)),
            run_seq: 0,
            git_log: Vec::new(),
            git_log_error: None,
        }
    }

    pub fn is_visible(&self) -> bool {
        !self.is_collapsed
    }

    fn render_diagnostics_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.diagnostics.is_empty() {
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(ThemeColors::text_muted())
                .child(crate::i18n::menu_text(cx, "diagnostics.empty").to_string())
                .into_any_element();
        }

        let rows: Vec<AnyElement> = self
            .diagnostics
            .iter()
            .enumerate()
            .map(|(index, diagnostic)| {
                let location = format!(
                    "{}:{}:{}",
                    diagnostic.file_path,
                    diagnostic.line + 1,
                    diagnostic.column + 1
                );
                let source = diagnostic
                    .source
                    .as_deref()
                    .unwrap_or("diagnostic")
                    .to_string();
                let path = diagnostic.file_path.clone();
                let line = diagnostic.line + 1;
                let severity_color = match diagnostic.severity.as_str() {
                    "error" => ThemeColors::destructive(),
                    "warning" => ThemeColors::warning(),
                    _ => ThemeColors::accent_blue(),
                };
                h_flex()
                    .id(format!("diagnostic-{index}"))
                    .w_full()
                    .items_start()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .cursor_pointer()
                    .hover(|row| row.bg(ThemeColors::accent()))
                    .child(
                        div()
                            .text_xs()
                            .font_weight(FontWeight::BOLD)
                            .text_color(severity_color)
                            .child(diagnostic.severity.clone()),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap_1()
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_primary())
                                    .child(diagnostic.message.clone()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_muted())
                                    .child(format!("{location} · {source}")),
                            ),
                    )
                    .on_click(cx.listener(move |_this, _event, _window, cx| {
                        cx.emit(BottomPanelEvent::OpenFile {
                            path: path.clone(),
                            line,
                        });
                    }))
                    .into_any_element()
            })
            .collect();

        div()
            .size_full()
            .overflow_y_scrollbar()
            .children(rows)
            .into_any_element()
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
        if tab == BottomTab::Run {
            // 打开即重探 Run 工程；reload_run_project 内已 notify。
            self.reload_run_project(cx);
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

    /// 更新工作目录并重探 Run 工程（替代直接写 `working_dir` 字段）。
    pub fn set_working_dir(&mut self, dir: String, cx: &mut Context<Self>) {
        self.working_dir = dir;
        self.reload_run_project(cx);
    }

    /// 重探 Run 工程：本地 `.lithe/run/configurations.json` 优先命中即 `Ready`；
    /// 否则先 `maven.scan`（payload `{root, paths}`）探测工程类型，再
    /// `runConfig.generate`（payload `{root}`，返回
    /// `{generated: {configurations[]}, entryCount}`）取配置列表，失败即 `Failed`。
    pub fn reload_run_project(&mut self, cx: &mut Context<Self>) {
        self.run_seq += 1;
        let seq = self.run_seq;
        self.run_project_name = crate::settings::project_dir_name(&self.working_dir).to_string();
        let local = read_local_run_configs(&self.working_dir);
        if !local.is_empty() {
            self.run_configs = local;
            self.keep_run_selection();
            self.run_state = RunProjectState::Ready;
            cx.notify();
            return;
        }
        self.run_state = RunProjectState::Loading;
        cx.notify();
        let client = self.client.clone();
        let root = self.working_dir.clone();
        cx.spawn(async move |this, cx| {
            // 先探 Maven 工程（只作工程类型参考；失败不直接 Failed，交给 generate 定夺）。
            let _ = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "maven.scan",
                    serde_json::json!({ "root": root, "paths": [] }),
                )
                .await;
            let generated = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "runConfig.generate",
                    serde_json::json!({ "root": root }),
                )
                .await;
            let _ = this.update(cx, |view, cx| {
                if view.run_seq != seq {
                    return;
                }
                match generated {
                    Ok(value) => {
                        view.run_configs = parse_generated_configs(&value);
                        // 无 LSP 时 generate 为空：本地文本扫描 main 方法兜底
                        //（对齐 Tauri 入口点发现，Linux 无 JDT 故用源码文本匹配）。
                        if view.run_configs.is_empty() {
                            view.run_configs = scan_java_mains(&root);
                        }
                        view.keep_run_selection();
                        view.run_state = if view.run_configs.is_empty() {
                            RunProjectState::Missing
                        } else {
                            RunProjectState::Ready
                        };
                    }
                    Err(err) => {
                        view.run_state = RunProjectState::Failed(err);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 运行选中配置；运行中则改为停止。
    pub fn run_selected_config(&mut self, cx: &mut Context<Self>) {
        if self.run_running {
            self.stop_running(cx);
            return;
        }
        let Some(item) = self.selected_run_item() else {
            return;
        };
        self.run_running = true;
        push_run_line(
            &mut self.run_output,
            format!(
                "{}：{}",
                crate::i18n::menu_text(cx, "run.starting"),
                item.name
            ),
        );
        cx.notify();
        let (tx, rx) = mpsc::channel::<String>();
        let child_slot = self.run_child.clone();
        let text = StepText::load(cx);
        let client = self.client.clone();
        let root = self.working_dir.clone();
        cx.spawn(async move |this, cx| {
            // 先问 core 要可执行计划（payload `{root, configurationId}`，返回
            // `{executable, arguments, workingDirectory}`）；本地配置或工具链
            // 未解析时拿不到可直跑的命令，退化到按 kind 拼的本地命令。
            let plan = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "runConfig.createLaunchPlan",
                    serde_json::json!({ "root": root, "configurationId": item.id }),
                )
                .await
                .ok();
            let steps = plan_to_steps(plan.as_ref(), &item, &root);
            let started = this.update(cx, |view, cx| {
                if steps.is_empty() {
                    view.run_running = false;
                    push_run_line(
                        &mut view.run_output,
                        crate::i18n::menu_text(cx, "run.noSteps").to_string(),
                    );
                    cx.notify();
                    return false;
                }
                let display = format!("$ {} {}", steps[0].program, steps[0].args.join(" "));
                push_run_line(&mut view.run_output, display.clone());
                view.record_run(&display, cx);
                cx.notify();
                true
            });
            if !matches!(started, Ok(true)) {
                return;
            }
            std::thread::spawn(move || run_steps_blocking(steps, child_slot, text, tx));
            // 输出泵：每行经 background 线程阻塞收，再回到主线程落盘展示。
            let rx = Arc::new(Mutex::new(rx));
            loop {
                let slot = rx.clone();
                let next = cx
                    .background_executor()
                    .spawn(async move {
                        let guard = slot.lock().ok()?;
                        guard.recv().ok()
                    })
                    .await;
                match next {
                    Some(line) => {
                        if this
                            .update(cx, |view, cx| {
                                push_run_line(&mut view.run_output, line);
                                cx.notify();
                            })
                            .is_err()
                        {
                            break;
                        }
                    }
                    None => break,
                }
            }
            let _ = this.update(cx, |view, cx| {
                view.run_running = false;
                cx.notify();
            });
        })
        .detach();
    }

    /// 停止在跑进程（Run 与 Maven 各自 kill；mvn 拉起的 java 孙进程不在此列）。
    pub fn stop_running(&mut self, cx: &mut Context<Self>) {
        let mut stopped = false;
        if let Ok(mut slot) = self.run_child.lock() {
            if let Some(child) = slot.as_mut() {
                let _ = child.kill();
                stopped = true;
            }
        }
        if let Ok(mut slot) = self.maven_child.lock() {
            if let Some(child) = slot.as_mut() {
                let _ = child.kill();
                stopped = true;
            }
        }
        if self.run_running {
            push_run_line(
                &mut self.run_output,
                crate::i18n::menu_text(cx, "run.stopping").to_string(),
            );
            stopped = true;
        }
        if self.maven_running {
            push_run_line(
                &mut self.maven_output,
                crate::i18n::menu_text(cx, "run.stopping").to_string(),
            );
            stopped = true;
        }
        if stopped {
            cx.notify();
        }
    }

    /// 是否发生过 Maven 运行；宿主据此决定左侧栏是否展示 maven 项
    ///（对齐 Tauri `hasMavenRun`：任务跑过即真，与终端历史无关）。
    pub fn has_maven_run(&self) -> bool {
        self.maven_running || !self.maven_output.is_empty()
    }

    /// 运行 Maven 目标：切 Maven 页 + 经 core `maven.launchPlan` 拿确定性参数
    ///（payload `{root, context: {version: 1, reactorPath: ".", profiles, skipTests}, module, goals}`），
    /// 起受管进程并把输出泵入 Maven 页（首行 `$ mvn …`，对齐 Tauri Maven 页）。
    /// 已有任务在跑时先停掉（对齐 Tauri 停掉上一个 session）。
    pub fn run_maven_goal(
        &mut self,
        pom_path: &str,
        goal: &str,
        target: &str,
        profiles: &[String],
        skip_tests: bool,
        cx: &mut Context<Self>,
    ) {
        let goal = goal.trim().to_string();
        if goal.is_empty() {
            return;
        }
        if self.maven_running {
            if let Ok(mut slot) = self.maven_child.lock() {
                if let Some(child) = slot.as_mut() {
                    let _ = child.kill();
                }
            }
        }
        self.maven_seq += 1;
        let seq = self.maven_seq;
        let title = format!("{goal} · {target}");
        self.last_maven_goal = Some(MavenGoalParams {
            pom_path: pom_path.to_string(),
            goal: goal.clone(),
            target: target.to_string(),
            profiles: profiles.to_vec(),
            skip_tests,
        });
        self.active_tab = BottomTab::Maven;
        self.is_collapsed = false;
        self.maven_title = Some(title.clone());
        self.maven_output.clear();
        self.maven_running = true;
        cx.notify();

        let client = self.client.clone();
        let root = self.working_dir.clone();
        let module = maven_module_for_pom(&self.working_dir, pom_path);
        let profiles = profiles.to_vec();
        let text = StepText::load(cx);
        let child_slot = self.maven_child.clone();
        cx.spawn(async move |this, cx| {
            let plan = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "maven.launchPlan",
                    serde_json::json!({
                        "root": root,
                        "context": {
                            "version": 1,
                            "reactorPath": ".",
                            "profiles": profiles,
                            "skipTests": skip_tests,
                        },
                        "module": module,
                        "goals": [goal],
                    }),
                )
                .await
                .ok();
            let (program, args, cwd) = maven_plan_to_step(plan.as_ref(), &root, &goal);
            let display = format!("$ {} {}", program, args.join(" "));
            let started = this.update(cx, |view, cx| {
                if view.maven_seq != seq {
                    return false;
                }
                push_run_line(&mut view.maven_output, display.clone());
                view.record_run(&display, cx);
                cx.notify();
                true
            });
            if !matches!(started, Ok(true)) {
                return;
            }
            let steps = vec![RunStep { program, args, cwd }];
            let (tx, rx) = mpsc::channel::<String>();
            std::thread::spawn(move || run_steps_blocking(steps, child_slot, text, tx));
            let rx = Arc::new(Mutex::new(rx));
            loop {
                let slot = rx.clone();
                let next = cx
                    .background_executor()
                    .spawn(async move {
                        let guard = slot.lock().ok()?;
                        guard.recv().ok()
                    })
                    .await;
                match next {
                    Some(line) => {
                        // `run_steps_blocking` 首行会再发一次 `$ …`，Maven 页已有
                        // 展示首行，跳过重复（对齐 Tauri 单首行）。
                        let skip = this
                            .update(cx, |view, cx| {
                                let duplicate = line.trim_start().starts_with("$ ")
                                    && !view.maven_output.is_empty();
                                if !duplicate {
                                    push_run_line(&mut view.maven_output, line);
                                }
                                cx.notify();
                                view.maven_seq == seq
                            })
                            .unwrap_or(false);
                        if !skip {
                            break;
                        }
                    }
                    None => break,
                }
            }
            let _ = this.update(cx, |view, cx| {
                if view.maven_seq == seq {
                    view.maven_running = false;
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 重跑上次 Maven 目标（头部重跑按钮，对齐 Tauri `rerunLastTest` 语义的子集：
    /// Linux 无测试会话跟踪，重跑即以上次参数再跑一次）。
    pub fn rerun_maven(&mut self, cx: &mut Context<Self>) {
        if self.maven_running {
            return;
        }
        if let Some(last) = self.last_maven_goal.clone() {
            self.run_maven_goal(
                &last.pom_path,
                &last.goal,
                &last.target,
                &last.profiles,
                last.skip_tests,
                cx,
            );
        }
    }

    /// 当前选中项（无选中或已失效时回退首项）。
    fn selected_run_item(&self) -> Option<RunConfigItem> {
        self.selected_run_config
            .as_deref()
            .and_then(|id| self.run_configs.iter().find(|c| c.id == id).cloned())
            .or_else(|| self.run_configs.first().cloned())
    }

    /// 保持选中有效：原选中仍在则不动，否则选首项。
    fn keep_run_selection(&mut self) {
        let keep = self
            .selected_run_config
            .as_ref()
            .is_some_and(|id| self.run_configs.iter().any(|c| &c.id == id));
        if !keep {
            self.selected_run_config = self.run_configs.first().map(|c| c.id.clone());
        }
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

    /// 窗格通用头部：图标 + 标题 + 状态区 + 操作按钮 + 最小化，
    /// 对齐 Tauri 各窗格自带按钮头（底部无标签切换条，切换只走左侧活动栏）。
    fn render_pane_header(
        &self,
        icon: IconName,
        title: String,
        status: Option<AnyElement>,
        buttons: Vec<AnyElement>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        h_flex()
            .h(px(30.0))
            .w_full()
            .flex_shrink_0()
            .bg(ThemeColors::bg_tab_bar())
            .border_b_1()
            .border_color(ThemeColors::border())
            .items_center()
            .gap_1()
            .px_2()
            .child(
                Icon::new(icon)
                    .size(px(14.0))
                    .text_color(ThemeColors::text_muted()),
            )
            .child(
                div()
                    .flex_1()
                    .truncate()
                    .text_xs()
                    .font_weight(FontWeight::BOLD)
                    .text_color(ThemeColors::text_primary())
                    .child(title),
            )
            .when_some(status, |el, status| el.child(status))
            .children(buttons)
            .child(
                Button::new("pane-minimize")
                    .small()
                    .ghost()
                    .icon(IconName::Minus)
                    .tooltip(crate::i18n::menu_text(cx, "run.minimize"))
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.toggle_collapsed(cx);
                    })),
            )
            .into_any_element()
    }

    /// 最小化之外的头部操作按钮（小幽灵图标按钮 + tooltip）。
    fn header_button(
        id: String,
        icon: IconName,
        tooltip: String,
        disabled: bool,
        cx: &mut Context<Self>,
        on_click: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) -> AnyElement {
        Button::new(id)
            .small()
            .ghost()
            .icon(icon)
            .tooltip(tooltip)
            .disabled(disabled)
            .on_click(cx.listener(move |this, _event, window, cx| {
                on_click(this, window, cx);
            }))
            .into_any_element()
    }

    /// Run 窗格头部：运行/停止 + 重扫 + 跟随末尾 + 清空 + 最小化
    ///（对齐 Tauri RunPane 头）。
    fn render_run_header(&self, cx: &mut Context<Self>) -> AnyElement {
        let running = self.run_running;
        let status = running.then(|| {
            div()
                .text_xs()
                .text_color(ThemeColors::accent_green())
                .child(crate::i18n::menu_text(cx, "run.running"))
                .into_any_element()
        });
        let title = format!(
            "{} {}",
            crate::i18n::menu_text(cx, "run.title"),
            self.run_project_name
        );
        let can_run = !matches!(self.run_state, RunProjectState::Loading);
        let follow_end = self.run_follow_end;
        let mut buttons = vec![
            Self::header_button(
                "run-toggle".to_string(),
                if running {
                    IconName::Square
                } else {
                    IconName::Play
                },
                crate::i18n::menu_text(cx, if running { "run.stop" } else { "run.run" })
                    .to_string(),
                !can_run,
                cx,
                |this, _window, cx| this.run_selected_config(cx),
            ),
            Self::header_button(
                "run-rescan".to_string(),
                IconName::RotateCw,
                crate::i18n::menu_text(cx, "run.rescan").to_string(),
                running,
                cx,
                |this, _window, cx| this.reload_run_project(cx),
            ),
        ];
        buttons.push(
            Button::new("run-follow-end")
                .small()
                .when(follow_end, |b| b.primary())
                .when(!follow_end, |b| b.ghost())
                .icon(IconName::ArrowDownToLine)
                .tooltip(crate::i18n::menu_text(cx, "run.scrollToEnd"))
                .on_click(cx.listener(|this, _event, _window, cx| {
                    this.run_follow_end = !this.run_follow_end;
                    crate::settings::update(cx, |s| {
                        s.run_scroll_to_end = this.run_follow_end;
                    });
                    // 打开跟随即滚到底（长度归零触发下次 render 滚动）。
                    this.run_followed_len = 0;
                    cx.notify();
                }))
                .into_any_element(),
        );
        buttons.push(Self::header_button(
            "run-clear-output".to_string(),
            IconName::Trash,
            crate::i18n::menu_text(cx, "run.clearOutput").to_string(),
            self.run_output.is_empty(),
            cx,
            |this, _window, cx| {
                this.run_output.clear();
                cx.notify();
            },
        ));
        self.render_pane_header(IconName::Play, title, status, buttons, cx)
    }

    /// Maven 窗格头部：停止 + 重跑 + 清空 + 最小化（对齐 Tauri MavenRunPane 头）。
    fn render_maven_header(&self, cx: &mut Context<Self>) -> AnyElement {
        let title = match self.maven_title.clone() {
            Some(task) => format!(
                "{} - {} - {task}",
                crate::i18n::menu_text(cx, "run.title"),
                crate::i18n::menu_text(cx, "maven.title")
            ),
            None => format!(
                "{} - {}",
                crate::i18n::menu_text(cx, "run.title"),
                crate::i18n::menu_text(cx, "maven.title")
            ),
        };
        let status = self.maven_running.then(|| {
            div()
                .text_xs()
                .text_color(ThemeColors::accent_green())
                .child(crate::i18n::menu_text(cx, "run.running"))
                .into_any_element()
        });
        let can_rerun = self.last_maven_goal.is_some() && !self.maven_running;
        let can_clear = !self.maven_output.is_empty() || self.maven_title.is_some();
        self.render_pane_header(
            IconName::Box,
            title,
            status,
            vec![
                Self::header_button(
                    "maven-stop".to_string(),
                    IconName::Square,
                    crate::i18n::menu_text(cx, "maven.stop").to_string(),
                    !self.maven_running,
                    cx,
                    |this, _window, cx| this.stop_running(cx),
                ),
                Self::header_button(
                    "maven-rerun".to_string(),
                    IconName::RefreshCw,
                    crate::i18n::menu_text(cx, "maven.rerunTest").to_string(),
                    !can_rerun,
                    cx,
                    |this, _window, cx| this.rerun_maven(cx),
                ),
                Self::header_button(
                    "maven-clear-output".to_string(),
                    IconName::Trash,
                    crate::i18n::menu_text(cx, "maven.clearOutput").to_string(),
                    !can_clear,
                    cx,
                    |this, _window, cx| {
                        this.maven_output.clear();
                        cx.notify();
                    },
                ),
            ],
            cx,
        )
    }

    /// Run 面板体：配置列表 + 输出区；头部由 `render_run_header` 负责。
    fn render_run_panel(&mut self, cx: &mut Context<Self>) -> AnyElement {
        if self.run_configs.is_empty() {
            match &self.run_state {
                RunProjectState::Loading => {
                    return run_center_text(run_ui_text(cx, "加载中…", "Loading…"));
                }
                RunProjectState::Failed(err) => {
                    let msg = if err.is_empty() {
                        run_ui_text(cx, "加载失败", "Failed to load")
                    } else {
                        err.clone()
                    };
                    return v_flex()
                        .size_full()
                        .items_center()
                        .justify_center()
                        .gap_2()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(div().child(msg))
                        .child(
                            Button::new("run-retry")
                                .small()
                                .ghost()
                                .label(run_ui_text(cx, "重试", "Retry"))
                                .on_click(cx.listener(|this, _event, _window, cx| {
                                    this.reload_run_project(cx);
                                })),
                        )
                        .into_any_element();
                }
                _ => {
                    // Missing 空态 + 生成配置按钮。
                    return v_flex()
                        .size_full()
                        .items_center()
                        .justify_center()
                        .gap_2()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(div().child(run_ui_text(
                            cx,
                            "暂无可运行配置",
                            "No runnable configurations",
                        )))
                        .child(
                            Button::new("run-generate")
                                .small()
                                .primary()
                                .label(run_ui_text(cx, "生成配置", "Generate"))
                                .on_click(cx.listener(|this, _event, _window, cx| {
                                    let root = this.working_dir.clone();
                                    let _ = append_default_run_config(&root);
                                    this.reload_run_project(cx);
                                })),
                        )
                        .into_any_element();
                }
            }
        }

        let rows: Vec<AnyElement> = self
            .run_configs
            .iter()
            .map(|item| {
                let id = item.id.clone();
                let run_id = item.id.clone();
                let selected = self.selected_run_config.as_deref() == Some(item.id.as_str());
                h_flex()
                    .id(format!("run-config-{}", item.id))
                    .w_full()
                    .items_center()
                    .gap_1p5()
                    .px_2()
                    .py_1()
                    .rounded_sm()
                    .cursor_pointer()
                    .text_xs()
                    .when(selected, |row| {
                        row.bg(ThemeColors::bg_tab_hover())
                            .text_color(ThemeColors::text_primary())
                    })
                    .when(!selected, |row| {
                        row.text_color(ThemeColors::text_muted()).hover(|h| {
                            h.bg(ThemeColors::bg_tab_hover())
                                .text_color(ThemeColors::text_primary())
                        })
                    })
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .child(div().truncate().child(item.name.clone()))
                            .child(
                                div()
                                    .truncate()
                                    .font_family("monospace")
                                    .child(format!("{} {}", item.kind, item.detail)),
                            ),
                    )
                    .child(
                        Button::new(format!("run-start-{}", item.id))
                            .small()
                            .ghost()
                            .icon(IconName::Play)
                            .tooltip(run_ui_text(cx, "运行", "Run"))
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.selected_run_config = Some(run_id.clone());
                                this.run_selected_config(cx);
                            })),
                    )
                    .on_click(cx.listener(move |this, _event, _window, cx| {
                        this.selected_run_config = Some(id.clone());
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();

        let total = self.run_output.len();
        let start = total.saturating_sub(800);
        let output: Vec<AnyElement> = if self.run_output.is_empty() {
            vec![div()
                .text_color(ThemeColors::text_muted())
                .child(crate::i18n::menu_text(cx, "run.emptyOutput"))
                .into_any_element()]
        } else {
            self.run_output[start..]
                .iter()
                .map(|line| render_output_line(line))
                .collect()
        };
        // 跟随末尾：只在新增输出时滚到最后一行（对齐 Tauri `useFollowOutputEnd`）。
        if self.run_follow_end && output.len() != self.run_followed_len {
            self.run_followed_len = output.len();
            if output.len() > 1 {
                self.run_scroll.scroll_to_item(output.len() - 1);
            }
        }

        v_flex()
            .size_full()
            .child(
                h_flex()
                    .flex_1()
                    .w_full()
                    .min_h_0()
                    .child(
                        div()
                            .flex_shrink_0()
                            .w(px(220.0))
                            .h_full()
                            .overflow_y_scrollbar()
                            .border_r_1()
                            .border_color(ThemeColors::border())
                            .py_1()
                            .children(rows),
                    )
                    .child(
                        div()
                            .flex_1()
                            .h_full()
                            .vertical_scrollbar(&self.run_scroll)
                            .p_2()
                            .font_family("monospace")
                            .text_xs()
                            .text_color(ThemeColors::text_primary())
                            .children(output),
                    ),
            )
            .into_any_element()
    }

    /// Maven 面板体：输出区（首行 `$ mvn …`，流式追加）；头部由 `render_maven_header` 负责。
    fn render_maven_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        let total = self.maven_output.len();
        let start = total.saturating_sub(800);
        let output: Vec<AnyElement> = if self.maven_output.is_empty() {
            vec![div()
                .text_color(ThemeColors::text_muted())
                .child(crate::i18n::menu_text(cx, "run.emptyOutput"))
                .into_any_element()]
        } else {
            self.maven_output[start..]
                .iter()
                .map(|line| render_output_line(line))
                .collect()
        };
        div()
            .flex_1()
            .w_full()
            .min_h_0()
            .overflow_y_scrollbar()
            .p_2()
            .font_family("monospace")
            .text_xs()
            .text_color(ThemeColors::text_primary())
            .children(output)
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

        // 各窗格自带按钮头（对齐 Tauri：底部无标签切换条，切换只走左侧活动栏）。
        let (header, body) = match self.active_tab {
            BottomTab::Terminal => (
                self.render_pane_header(
                    IconName::Terminal,
                    crate::i18n::menu_text(cx, "workbench.terminal").to_string(),
                    None,
                    vec![Self::header_button(
                        "terminal-clear".to_string(),
                        IconName::Trash,
                        crate::i18n::menu_text(cx, "ui.clear").to_string(),
                        false,
                        cx,
                        |this, _window, cx| {
                            let _ = this.terminal.update(cx, |t, cx| t.clear(cx));
                        },
                    )],
                    cx,
                ),
                div()
                    .size_full()
                    .child(self.terminal.clone())
                    .into_any_element(),
            ),
            BottomTab::Run => (self.render_run_header(cx), self.render_run_panel(cx)),
            BottomTab::Maven => (self.render_maven_header(cx), self.render_maven_panel(cx)),
            BottomTab::Diagnostics => (
                self.render_pane_header(
                    IconName::TriangleAlert,
                    format!(
                        "{} ({})",
                        crate::i18n::menu_text(cx, "workbench.diagnostics"),
                        self.diagnostics.len()
                    ),
                    None,
                    vec![Self::header_button(
                        "diagnostics-clear".to_string(),
                        IconName::Trash,
                        crate::i18n::menu_text(cx, "ui.clear").to_string(),
                        self.diagnostics.is_empty(),
                        cx,
                        |this, _window, cx| {
                            this.diagnostics.clear();
                            cx.notify();
                        },
                    )],
                    cx,
                ),
                self.render_diagnostics_panel(cx),
            ),
            BottomTab::GitLog => (
                self.render_pane_header(
                    IconName::GitGraph,
                    crate::i18n::menu_text(cx, "workbench.gitLog").to_string(),
                    None,
                    vec![Self::header_button(
                        "gitlog-refresh".to_string(),
                        IconName::RotateCw,
                        crate::i18n::menu_text(cx, "ui.refresh").to_string(),
                        false,
                        cx,
                        |this, _window, cx| this.refresh_git_log(cx),
                    )],
                    cx,
                ),
                self.render_git_log_panel(cx),
            ),
        };

        v_flex()
            .h(px(self.height))
            .w_full()
            .bg(ThemeColors::bg_bottom_panel())
            .border_t_1()
            .border_color(ThemeColors::border())
            .child(header)
            .child(div().flex_1().w_full().min_h_0().child(body))
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

/// 读本地运行配置（`<workspace>/.lithe/run/configurations.json`），兼容数组与
/// `{configurations: []}` 两种形状；字段沿用 v1 形态（`name/type/mainClass`）。
fn read_local_run_configs(workspace_root: &str) -> Vec<RunConfigItem> {
    let path = std::path::Path::new(workspace_root)
        .join(".lithe")
        .join("run")
        .join("configurations.json");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
        return Vec::new();
    };
    let arr = if let Some(arr) = value.as_array() {
        arr.clone()
    } else if let Some(arr) = value.get("configurations").and_then(|v| v.as_array()) {
        arr.clone()
    } else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|item| {
            let name = item.get("name")?.as_str()?;
            let kind_raw = item.get("type").and_then(|t| t.as_str()).unwrap_or("java");
            let main_class = item
                .get("mainClass")
                .and_then(|m| m.as_str())
                .map(str::to_string);
            let kind = if kind_raw.contains("npm") || kind_raw.contains("node") {
                "npm"
            } else if kind_raw.contains("maven") {
                "maven"
            } else {
                "mainClass"
            };
            let detail = main_class.clone().unwrap_or_else(|| kind_raw.to_string());
            Some(RunConfigItem {
                id: name.to_string(),
                name: name.to_string(),
                kind: kind.to_string(),
                detail,
                main_class,
                source: None,
            })
        })
        .collect()
}

/// 追加一个默认 Java 运行配置（保留已有配置），供 Missing 空态的生成按钮用。
fn append_default_run_config(workspace_root: &str) -> bool {
    let path = std::path::Path::new(workspace_root)
        .join(".lithe")
        .join("run")
        .join("configurations.json");
    if let Some(parent) = path.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return false;
        }
    }
    let mut list: Vec<serde_json::Value> = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .and_then(|v| {
            if let Some(arr) = v.as_array() {
                Some(arr.clone())
            } else {
                v.get("configurations").and_then(|c| c.as_array()).cloned()
            }
        })
        .unwrap_or_default();
    list.push(serde_json::json!({"name": "Run Main", "type": "java", "mainClass": "Main"}));
    let value = serde_json::json!({"configurations": list});
    serde_json::to_string_pretty(&value)
        .ok()
        .and_then(|text| std::fs::write(&path, text).ok())
        .is_some()
}

/// 解析 `runConfig.generate` 返回的 `{generated: {configurations[]}}`。
/// 本地 Java 入口扫描：无 LSP 时的兜底（对齐 Tauri `discoverJavaEntrypoints`，
/// Linux 无 JDT 故用源码文本匹配 `public static void main`）。
/// 主类由 `package` 声明 + 文件名推导；上限 20 个，按路径排序保证稳定。
fn scan_java_mains(root: &str) -> Vec<RunConfigItem> {
    const MAX_MAINS: usize = 20;
    const MAX_DEPTH: usize = 8;
    const SKIP_DIRS: &[&str] = &[
        "target",
        "build",
        "out",
        "dist",
        "node_modules",
        ".git",
        ".idea",
        ".vscode",
        "vendor",
    ];
    const MAX_FILE_BYTES: u64 = 512 * 1024;

    fn walk(dir: &std::path::Path, depth: usize, out: &mut Vec<std::path::PathBuf>) {
        if depth > MAX_DEPTH || out.len() >= MAX_MAINS * 4 {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        let mut entries: Vec<_> = entries.filter_map(|e| e.ok()).collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if path.is_dir() {
                if !name.starts_with('.') && !SKIP_DIRS.contains(&name.as_str()) {
                    walk(&path, depth + 1, out);
                }
            } else if name.ends_with(".java") {
                out.push(path);
            }
        }
    }

    fn package_of(text: &str) -> Option<String> {
        text.lines().find_map(|line| {
            let line = line.trim();
            line.strip_prefix("package ")
                .and_then(|rest| rest.strip_suffix(';'))
                .map(|pkg| pkg.trim().to_string())
                .filter(|pkg| {
                    !pkg.is_empty()
                        && pkg
                            .chars()
                            .all(|c| c.is_alphanumeric() || c == '.' || c == '_')
                })
        })
    }

    let root_path = std::path::Path::new(root);
    let mut files = Vec::new();
    walk(root_path, 0, &mut files);
    let mut items = Vec::new();
    for path in files {
        if items.len() >= MAX_MAINS {
            break;
        }
        if std::fs::metadata(&path).is_ok_and(|m| m.len() > MAX_FILE_BYTES) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        if !text.contains("public static void main") {
            continue;
        }
        let stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        if stem.is_empty() {
            continue;
        }
        let main_class = match package_of(&text) {
            Some(pkg) => format!("{pkg}.{stem}"),
            None => stem,
        };
        let source = path
            .strip_prefix(root_path)
            .map(|p| p.to_string_lossy().replace('\\', "/"))
            .unwrap_or_default();
        items.push(RunConfigItem {
            id: format!("local-main:{main_class}"),
            name: main_class.clone(),
            kind: "mainClass".to_string(),
            detail: main_class.clone(),
            main_class: Some(main_class),
            source: Some(source),
        });
    }
    items.sort_by(|a, b| a.name.cmp(&b.name));
    items
}

fn parse_generated_configs(value: &serde_json::Value) -> Vec<RunConfigItem> {
    value
        .get("generated")
        .and_then(|g| g.get("configurations"))
        .and_then(|c| c.as_array())
        .map(|arr| arr.iter().filter_map(config_item_from_generated).collect())
        .unwrap_or_default()
}

fn config_item_from_generated(item: &serde_json::Value) -> Option<RunConfigItem> {
    let id = item.get("id")?.as_str()?;
    let name = item.get("name").and_then(|n| n.as_str()).unwrap_or(id);
    let provider = item.get("provider").and_then(|p| p.as_str()).unwrap_or("");
    let command = item.get("command").and_then(|c| c.as_str()).unwrap_or("");
    let maven = &item["extensions"]["maven"];
    let main_class = maven
        .get("mainClass")
        .and_then(|m| m.as_str())
        .map(str::to_string);
    let module = maven
        .get("module")
        .and_then(|m| m.as_str())
        .map(str::to_string);
    let source = item
        .get("extensions")
        .and_then(|e| e.get("java"))
        .and_then(|j| j.get("source"))
        .and_then(|s| s.as_str())
        .map(str::to_string);
    let kind = if provider.contains("npm") || provider.contains("node") || command == "npm" {
        "npm"
    } else if provider.contains("maven") {
        "maven"
    } else {
        "mainClass"
    };
    let detail = if kind == "npm" {
        item.get("args")
            .and_then(|a| a.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str())
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "run dev".to_string())
    } else {
        main_class
            .clone()
            .or(module.clone())
            .unwrap_or_else(|| provider.to_string())
    };
    Some(RunConfigItem {
        id: id.to_string(),
        name: name.to_string(),
        kind: kind.to_string(),
        detail,
        main_class,
        source,
    })
}

/// 由 `createLaunchPlan` 结果拼直跑步骤：只有 `executable.command`
/// 是真实可执行路径；`executable.toolchain` 需宿主解析，拿不到就走退化。
fn plan_to_steps(
    plan: Option<&serde_json::Value>,
    item: &RunConfigItem,
    root: &str,
) -> Vec<RunStep> {
    if let Some(plan) = plan {
        let cwd = plan
            .get("workingDirectory")
            .and_then(|v| v.as_str())
            .unwrap_or(".");
        let cwd = if cwd == "." || cwd.is_empty() {
            root.to_string()
        } else {
            format!("{root}/{cwd}")
        };
        if let Some(command) = plan
            .get("executable")
            .and_then(|e| e.get("command"))
            .and_then(|c| c.as_str())
            .filter(|c| !c.is_empty())
        {
            let args = plan
                .get("arguments")
                .and_then(|a| a.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();
            return vec![RunStep {
                program: command.to_string(),
                args,
                cwd,
            }];
        }
    }
    fallback_run_steps(item, root)
}

/// pom 所在目录相对 root 的模块路径：根 pom 为 `.`，与 core 模块约定一致。
fn maven_module_for_pom(root: &str, pom: &str) -> String {
    let relative = std::path::Path::new(pom)
        .parent()
        .and_then(|dir| dir.strip_prefix(root).ok())
        .map(|rel| rel.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default();
    let trimmed = relative.trim_matches('/').to_string();
    if trimmed.is_empty() {
        ".".to_string()
    } else {
        trimmed
    }
}

/// `maven.launchPlan`（`{executable.toolchain, arguments[], workingDirectory}`）
/// 转本地执行步骤；拿不到计划时退化为 `mvn <goal>`。
fn maven_plan_to_step(
    plan: Option<&serde_json::Value>,
    root: &str,
    goal: &str,
) -> (String, Vec<String>, String) {
    if let Some(plan) = plan {
        let cwd = plan
            .get("workingDirectory")
            .and_then(|v| v.as_str())
            .unwrap_or(".");
        let cwd = if cwd == "." || cwd.is_empty() {
            root.to_string()
        } else {
            format!("{root}/{cwd}")
        };
        let args = plan
            .get("arguments")
            .and_then(|a| a.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect::<Vec<_>>()
            })
            .filter(|args| !args.is_empty());
        if let Some(args) = args {
            return (resolve_maven_executable(root), args, cwd);
        }
    }
    (
        resolve_maven_executable(root),
        vec![goal.to_string()],
        root.to_string(),
    )
}

/// 退化执行规则：maven 用 mvn 跑 `compile exec:java`；npm 跑 `run dev`；
/// java 单文件走 javac+java，否则直跑主类。
fn fallback_run_steps(item: &RunConfigItem, root: &str) -> Vec<RunStep> {
    match item.kind.as_str() {
        "maven" => {
            let mut args = vec!["-B".to_string(), "-ntp".to_string(), "compile".to_string()];
            if let Some(main) = item.main_class.as_deref().filter(|s| !s.is_empty()) {
                args.push("exec:java".to_string());
                args.push(format!("-Dexec.mainClass={main}"));
            }
            vec![RunStep {
                program: resolve_maven_executable(root),
                args,
                cwd: root.to_string(),
            }]
        }
        "npm" => vec![RunStep {
            program: "npm".to_string(),
            args: vec!["run".to_string(), pick_npm_script(root)],
            cwd: root.to_string(),
        }],
        _ => {
            let classes = format!("{root}/.lithe/run/classes");
            if let (Some(source), Some(main)) = (item.source.as_deref(), item.main_class.as_deref())
            {
                let abs = format!("{root}/{source}");
                if !source.is_empty() && !main.is_empty() && std::path::Path::new(&abs).is_file() {
                    let _ = std::fs::create_dir_all(&classes);
                    return vec![
                        RunStep {
                            program: "javac".to_string(),
                            args: vec!["-d".to_string(), classes.clone(), abs],
                            cwd: root.to_string(),
                        },
                        RunStep {
                            program: "java".to_string(),
                            args: vec!["-cp".to_string(), classes, main.to_string()],
                            cwd: root.to_string(),
                        },
                    ];
                }
            }
            let main = item.main_class.clone().unwrap_or_else(|| item.name.clone());
            vec![RunStep {
                program: "java".to_string(),
                args: vec![main],
                cwd: root.to_string(),
            }]
        }
    }
}

/// mvn 路径：先看 `.lithe/run/local.json` 的 `mavenExecutablePath`
///（含 `toolchain` 下），没有就用 `PATH` 里的 `mvn`。
fn resolve_maven_executable(root: &str) -> String {
    let path = std::path::Path::new(root)
        .join(".lithe")
        .join("run")
        .join("local.json");
    let from_file = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .and_then(|value| {
            value
                .get("mavenExecutablePath")
                .or_else(|| {
                    value
                        .get("toolchain")
                        .and_then(|t| t.get("mavenExecutablePath"))
                })
                .and_then(|v| v.as_str())
                .map(str::to_string)
        })
        .filter(|s| !s.trim().is_empty());
    from_file.unwrap_or_else(|| "mvn".to_string())
}

/// npm 脚本选择：`package.json` 有 dev 用 dev，否则 start，再没有还用 dev（报错由输出展示）。
fn pick_npm_script(root: &str) -> String {
    let has = |name: &str, value: &serde_json::Value| {
        value.get("scripts").and_then(|s| s.get(name)).is_some()
    };
    std::fs::read_to_string(std::path::Path::new(root).join("package.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .map(|value| {
            if has("dev", &value) {
                "dev".to_string()
            } else if has("start", &value) {
                "start".to_string()
            } else {
                "dev".to_string()
            }
        })
        .unwrap_or_else(|| "dev".to_string())
}

/// 顺序跑步骤并把输出行推入 channel；首个失败步骤后停。stdout/stderr 各一根
/// 转发线程；子进程句柄共享给停止按钮，`try_wait` 短锁轮询避免 `wait`
/// 占锁导致 kill 拿不到锁。
fn run_steps_blocking(
    steps: Vec<RunStep>,
    child_slot: Arc<Mutex<Option<std::process::Child>>>,
    text: StepText,
    tx: mpsc::Sender<String>,
) {
    use std::io::BufRead as _;
    for step in &steps {
        let _ = tx.send(format!("$ {} {}", step.program, step.args.join(" ")));
        let mut child = match std::process::Command::new(&step.program)
            .args(&step.args)
            .current_dir(&step.cwd)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
        {
            Ok(child) => child,
            Err(err) => {
                let _ = tx.send(format!("{}：{err}", text.start_failed));
                return;
            }
        };
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        if let Ok(mut slot) = child_slot.lock() {
            *slot = Some(child);
        }
        let tx_out = tx.clone();
        let out_handle = stdout.map(|out| {
            std::thread::spawn(move || {
                for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
                    if tx_out.send(line).is_err() {
                        break;
                    }
                }
            })
        });
        let tx_err = tx.clone();
        let err_handle = stderr.map(|err| {
            std::thread::spawn(move || {
                for line in std::io::BufReader::new(err).lines().map_while(Result::ok) {
                    if tx_err.send(line).is_err() {
                        break;
                    }
                }
            })
        });
        let status = loop {
            let Ok(mut slot) = child_slot.lock() else {
                break None;
            };
            match slot.as_mut().map(|child| child.try_wait()) {
                Some(Ok(Some(status))) => break Some(status),
                Some(Ok(None)) => {
                    drop(slot);
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                _ => break None,
            }
        };
        if let Some(handle) = out_handle {
            let _ = handle.join();
        }
        if let Some(handle) = err_handle {
            let _ = handle.join();
        }
        if let Ok(mut slot) = child_slot.lock() {
            let _ = slot.take();
        }
        match status {
            Some(status) if status.success() => {
                let _ = tx.send(format!("{}：0", text.exit_code));
            }
            Some(status) => {
                let _ = tx.send(format!("{}：{status}", text.exited));
                return;
            }
            None => {
                let _ = tx.send(text.finished.clone());
                return;
            }
        }
    }
}

/// 行首空白转不换行空格：GPUI `Normal` 会塌缩连续空白（Tauri `pre-wrap`
/// 保留），只转行首以兼顾缩进保留与行内换行。
fn preserve_leading_whitespace(line: &str) -> String {
    let indent_len = line.len() - line.trim_start_matches([' ', '\t']).len();
    let (indent, rest) = line.split_at(indent_len);
    let mut out = String::with_capacity(line.len() + indent.len() * 2);
    for c in indent.chars() {
        if c == '\t' {
            out.push_str("\u{a0}\u{a0}\u{a0}\u{a0}");
        } else {
            out.push('\u{a0}');
        }
    }
    out.push_str(rest);
    out
}

/// 输出行渲染：显式换行模式（对齐 Tauri `pre-wrap`）+ 行首缩进保留。
fn render_output_line(line: &str) -> AnyElement {
    div()
        .whitespace_normal()
        .child(preserve_leading_whitespace(line))
        .into_any_element()
}
fn push_run_line(output: &mut Vec<String>, line: String) {
    output.push(line);
    if output.len() > MAX_RUN_OUTPUT {
        let overflow = output.len() - MAX_RUN_OUTPUT;
        output.drain(..overflow);
    }
}

fn run_center_text(text: String) -> AnyElement {
    div()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .text_xs()
        .text_color(ThemeColors::text_muted())
        .child(text)
        .into_any_element()
}

fn run_ui_text(cx: &gpui_kit::App, zh: &str, en: &str) -> String {
    if crate::i18n::is_zh(cx) {
        zh.to_string()
    } else {
        en.to_string()
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
