//! RunPanel 的命令与生命周期：配置加载、会话启动/停止和输出合批。

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

use async_channel::Receiver;
use gpui_kit::component::resizable::ResizableState;
use gpui_kit::{App, AppContext as _, Context, Entity, KeyBinding, SharedString, Task, Window};
use lithe_core_client::CoreClient;
use lithe_git_host::ProcessTree;
use lithe_ui::i18n::tr;

use crate::console::ConsoleScroll;

use super::config::{self, LoadedRunConfigurations};
use super::model::{RunConfiguration, RunExecution, RunScope};
use super::session::{self, RunMode, SessionEvent};
use super::state::SessionState;
use super::{
    CONFIGURATION_LIST_DEFAULT_WIDTH, CONSOLE_CONTEXT, CopySelection, OUTPUT_FLUSH_INTERVAL,
    RunPanel, RunPanelEvent,
};
use crate::language::{JavaLanguageServiceEvent, JavaLanguageServiceModel};

impl RunPanel {
    pub fn new(
        client: CoreClient,
        root: PathBuf,
        java_language: Entity<JavaLanguageServiceModel>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let root = config::normalize_root(root);
        // 控制台的复制快捷键只在控制台自己的键上下文里生效；这里注册一次，
        // 由控制台根元素的 `key_context` 决定是否匹配。
        cx.bind_keys([
            KeyBinding::new("cmd-c", CopySelection, Some(CONSOLE_CONTEXT)),
            KeyBinding::new("ctrl-c", CopySelection, Some(CONSOLE_CONTEXT)),
        ]);
        // 配置列表 / 输出的分栏状态：拖拽期间由 gpui-kit 维护，提交后回写宽度。
        let split_state = cx.new(|_| ResizableState::default());
        cx.observe(&split_state, |_, _, cx| cx.notify()).detach();
        // 准备状态由模型驱动：状态变化时放行被闸门拦下的启动。
        cx.subscribe(
            &java_language,
            |this, _, _: &JavaLanguageServiceEvent, cx| {
                this.resume_pending_java_launch(cx);
                cx.notify();
            },
        )
        .detach();
        Self {
            client,
            pending_initial_load: root.is_some(),
            root,
            configurations: Vec::new(),
            default_id: None,
            selected_id: None,
            scope: RunScope::All,
            pinned: HashSet::new(),
            sessions: BTreeMap::new(),
            diagnostics: Vec::new(),
            loading: false,
            error: None,
            generation: 0,
            pending_run: false,
            restart_pending: None,
            wrap_output: false,
            show_details: false,
            split_state,
            configuration_width: CONFIGURATION_LIST_DEFAULT_WIDTH,
            batch_selection: false,
            checked: HashSet::new(),
            collapsed_groups: HashSet::new(),
            more_menu: None,
            _more_menu_subscription: None,
            selected_language: None,
            console: ConsoleScroll::new(),
            console_follow_tail: true,
            console_focus: cx.focus_handle(),
            pending_output: BTreeMap::new(),
            output_flush_scheduled: false,
            on_before_launch: None,
            java_build_policy: None,
            set_java_build_policy: None,
            on_open_settings: None,
            preparation_expanded: false,
            java_language,
            pending_java_launch: None,
            launch_decision: None,
            launch_decision_target: None,
        }
    }

    /// 注入启动前保存回调。工作台在构造期注册一次，面板每次启动前调用。
    pub fn on_before_launch(
        &mut self,
        handler: impl Fn(&mut App) -> Task<Result<Option<PathBuf>, String>> + 'static,
    ) {
        self.on_before_launch = Some(Rc::new(handler));
    }

    /// 注入 Java 构建失败策略的读写回调（按工作区持久化）。
    pub fn on_java_build_policy(
        &mut self,
        read: impl Fn(&mut App, &Path) -> bool + 'static,
        write: impl Fn(&mut App, &Path, bool) + 'static,
    ) {
        self.java_build_policy = Some(Rc::new(read));
        self.set_java_build_policy = Some(Rc::new(write));
    }

    /// 注入「编辑当前配置」回调：打开设置页的 Run Configurations 页。
    pub fn on_open_settings(&mut self, handler: impl Fn(&str, &mut Window, &mut App) + 'static) {
        self.on_open_settings = Some(Rc::new(handler));
    }

    /// 外部保存或重新识别配置后刷新列表。
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        if self.root.is_some() {
            self.reload(cx);
        }
    }

    /// 切换项目根目录；旧会话先停止，旧配置和诊断全部清空。
    pub fn set_root(&mut self, root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        self.stop_all(cx);
        self.root = config::normalize_root(root);
        self.generation = self.generation.wrapping_add(1);
        self.configurations.clear();
        self.default_id = None;
        self.selected_id = None;
        self.diagnostics.clear();
        self.sessions.clear();
        self.pending_output.clear();
        self.error = None;
        self.loading = false;
        self.pending_run = false;
        self.restart_pending = None;
        self.pending_initial_load = self.root.is_some();
        self.launch_decision = None;
        self.launch_decision_target = None;
        self.emit(cx);
        cx.notify();
    }

    /// 查找某个 Maven 模块可明确选择的运行配置。
    ///
    /// 对齐 Tauri `findMavenModuleRunConfiguration`：配置必须带 Maven 扩展、
    /// 反应堆根与模块路径都匹配，且是可执行的应用 / 服务配置；优先返回
    /// 固定默认配置，候选多于一个且无默认时返回 `None`（不猜测）。
    pub fn maven_module_run_configuration(
        &self,
        reactor_path: &str,
        module_path: &str,
    ) -> Option<String> {
        let candidates: Vec<&RunConfiguration> = self
            .configurations
            .iter()
            .filter(|configuration| {
                matches!(
                    configuration.execution,
                    RunExecution::Application | RunExecution::Service
                )
            })
            .filter(|configuration| {
                let reactor = normalize_relative(configuration.maven_reactor_path());
                let module = normalize_relative(configuration.module());
                reactor == normalize_relative(Some(reactor_path))
                    && module == normalize_relative(Some(module_path))
            })
            .collect();
        let configured_default = candidates
            .iter()
            .find(|configuration| Some(configuration.id.as_str()) == self.default_id.as_deref());
        if let Some(configuration) = configured_default {
            return Some(configuration.id.clone());
        }
        if candidates.len() == 1 {
            return Some(candidates[0].id.clone());
        }
        None
    }

    /// 选择并启动指定 id 的配置。Maven 工具窗的模块 Run 动作使用。
    pub fn run_configuration(&mut self, id: &str, cx: &mut Context<Self>) {
        self.selected_id = Some(id.to_string());
        self.start_configuration(id.to_string(), cx);
    }

    /// 当前选中配置名，供顶栏配置 pill 显示。
    pub fn selected_label(&self) -> SharedString {
        self.selected_configuration()
            .map(|configuration| configuration.name.clone())
            .unwrap_or_else(|| tr("Run configuration").to_string())
            .into()
    }

    /// 是否有任一配置正在启动或运行。
    pub fn is_running(&self) -> bool {
        self.sessions.values().any(SessionState::is_active)
    }

    /// 当前选中配置是否正在运行。
    pub fn selected_is_running(&self) -> bool {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .is_some_and(|session| session.running)
    }

    pub(super) fn invoke_open_settings(
        &self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(handler) = self.on_open_settings.as_ref() {
            handler(id, window, cx);
        }
    }

    /// 顶栏 Run / F5：执行当前配置；没有配置时先加载再执行。
    pub fn run_selected(&mut self, cx: &mut Context<Self>) {
        if self.configurations.is_empty() {
            self.pending_run = true;
            if !self.loading {
                self.reload(cx);
            }
            return;
        }
        let candidate = self
            .selected_id
            .clone()
            .or_else(|| self.default_id.clone())
            .and_then(|id| {
                self.configurations
                    .iter()
                    .find(|configuration| configuration.id == id)
                    .filter(|configuration| configuration.execution != RunExecution::Group)
                    .map(|configuration| configuration.id.clone())
            })
            .or_else(|| {
                self.configurations
                    .iter()
                    .find(|configuration| configuration.execution != RunExecution::Group)
                    .map(|configuration| configuration.id.clone())
            });
        if let Some(id) = candidate {
            if self.sessions.get(&id).is_some_and(SessionState::is_active) {
                self.restart_configuration(id, cx);
            } else {
                self.start_configuration(id, cx);
            }
        }
    }

    /// 顶栏 Stop：停止当前选中配置。
    pub fn stop_selected(&mut self, cx: &mut Context<Self>) {
        if let Some(id) = self.selected_id.clone() {
            self.stop_configuration(&id, cx);
        }
    }

    /// 停止当前活跃的运行会话（菜单 `run.stop` / Tauri `debug.stop` 的语义）。
    ///
    /// 优先停止选中配置；若选中的没在跑（例如运行后又切换了选中项），停止
    /// 所有仍在启动/运行的会话，保证菜单启用时点击一定有真实效果。
    pub fn stop_active(&mut self, cx: &mut Context<Self>) {
        let selected_active = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .is_some_and(SessionState::is_active);
        if selected_active {
            self.stop_selected(cx);
            return;
        }
        let active: Vec<String> = self
            .sessions
            .iter()
            .filter(|(_, session)| session.is_active())
            .map(|(id, _)| id.clone())
            .collect();
        for id in active {
            self.stop_configuration(&id, cx);
        }
    }

    pub(super) fn selected_configuration(&self) -> Option<&RunConfiguration> {
        let id = self.selected_id.as_ref()?;
        self.configurations
            .iter()
            .find(|configuration| &configuration.id == id)
    }

    /// 当前选中会话的输出文本。
    ///
    /// 只用于复制、打印、诊断这类需要全文的一次性动作；渲染走虚拟化列表，
    /// 不再每帧拼接整段输出。
    pub(super) fn selected_output(&self) -> String {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .map(SessionState::full_text)
            .unwrap_or_default()
    }

    /// 当前选中会话展示的行数与行文本访问器。
    pub(super) fn selected_line_count(&self) -> usize {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .map(SessionState::display_line_count)
            .unwrap_or(0)
    }

    /// 是否有任一控制台输出了内容。
    pub(super) fn selected_has_output(&self) -> bool {
        self.selected_line_count() > 0
    }

    /// 当前选中会话采用的启动方式；没有运行记录时为 `None`。
    pub(super) fn selected_run_mode(&self) -> Option<RunMode> {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .and_then(|session| session.mode)
    }

    /// 首次显示时加载配置。构造期不能 spawn。
    pub(super) fn ensure_loaded(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.pending_initial_load {
            return;
        }
        self.pending_initial_load = false;
        cx.defer_in(window, |this, _window, cx| {
            if this.root.is_some() {
                this.reload(cx);
            }
        });
    }

    /// 后台读取/生成/解析运行配置。
    pub(super) fn reload(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            self.configurations.clear();
            self.loading = false;
            self.error = Some(tr("Open a project to discover run configurations").into());
            self.emit(cx);
            cx.notify();
            return;
        };

        self.pending_initial_load = false;
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.loading = true;
        self.error = None;
        self.emit(cx);
        cx.notify();

        let client = self.client;
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move { config::load_configurations(&client, &root) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading = false;
                match result {
                    Ok(loaded) => this.apply_loaded(loaded, cx),
                    Err(error) => {
                        this.error = Some(SharedString::from(error));
                        this.emit(cx);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    fn apply_loaded(&mut self, loaded: LoadedRunConfigurations, cx: &mut Context<Self>) {
        self.configurations = loaded.configurations;
        self.default_id = loaded.default_id;
        self.diagnostics = loaded.diagnostics;
        if self
            .selected_id
            .as_ref()
            .is_none_or(|id| !self.configurations.iter().any(|item| &item.id == id))
        {
            self.selected_id = self
                .default_id
                .clone()
                .or_else(|| self.configurations.first().map(|item| item.id.clone()));
        }
        self.pending_initial_load = false;
        self.emit(cx);
        cx.notify();

        if self.pending_run {
            self.pending_run = false;
            if !self.configurations.is_empty() {
                self.run_selected(cx);
            }
        }
    }

    /// 重新运行：先停止当前会话，等 Exited 事件到达后再启动。
    pub(super) fn restart_configuration(&mut self, id: String, cx: &mut Context<Self>) {
        if self.sessions.get(&id).is_some_and(SessionState::is_active) {
            self.restart_pending = Some(id.clone());
            self.stop_configuration(&id, cx);
        } else {
            self.start_configuration(id, cx);
        }
    }

    pub(super) fn watch_session(
        &mut self,
        id: String,
        receiver: Receiver<SessionEvent>,
        cx: &mut Context<Self>,
    ) {
        let task: Task<()> = cx.spawn(async move |this, cx| {
            while let Ok(event) = receiver.recv().await {
                let keep = this
                    .update(cx, |this, cx| this.handle_session_event(&id, event, cx))
                    .unwrap_or(false);
                if !keep {
                    break;
                }
            }
        });
        task.detach();
    }

    fn handle_session_event(
        &mut self,
        id: &str,
        event: SessionEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        let is_output = matches!(&event, SessionEvent::Output(_));
        let mut output_chunk: Option<String> = None;
        let mut failed_output: Option<String> = None;
        if let Some(session) = self.sessions.get_mut(id) {
            match event {
                // 输出不在这里直接入账：高频日志先合批，避免每个数据块都触发
                // 一次整段控制台重排。
                SessionEvent::Output(text) => output_chunk = Some(text),
                SessionEvent::LaunchMode(mode) => session.mode = Some(mode),
                SessionEvent::Started(tree) => {
                    session.tree = Some(tree);
                    session.starting = false;
                    session.running = true;
                }
                SessionEvent::Exited(code) => {
                    session.starting = false;
                    session.running = false;
                    session.exit_code = code;
                    session.tree = None;
                    // 进程最后一行通常没有换行；不补进列表就会丢最后一条输出。
                    session.flush_pending_line();
                }
                SessionEvent::Failed(message) => {
                    session.starting = false;
                    session.running = false;
                    session.exit_code = Some(1);
                    session.tree = None;
                    session.flush_pending_line();
                    failed_output = Some(format!("{message}\n"));
                }
            }
        }
        if let Some(text) = output_chunk {
            self.queue_output(id, &text, cx);
        }
        if let Some(text) = failed_output {
            // 启动失败要立刻可见，不受合批窗口影响。
            self.pending_output
                .entry(id.to_string())
                .or_default()
                .push_str(&text);
            self.flush_output(cx);
        }

        if self.restart_pending.as_deref() == Some(id)
            && !self.sessions.get(id).is_some_and(SessionState::is_active)
        {
            self.restart_pending = None;
            self.start_configuration(id.to_string(), cx);
        }

        if !is_output {
            self.emit(cx);
            cx.notify();
        }
        true
    }

    /// 把输出块放进合批缓冲；窗口到期后一次性追加。
    fn queue_output(&mut self, id: &str, text: &str, cx: &mut Context<Self>) {
        self.pending_output
            .entry(id.to_string())
            .or_default()
            .push_str(text);
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

    /// 合并缓冲里所有配置的输出，只刷新一次视图。
    fn flush_output(&mut self, cx: &mut Context<Self>) {
        if self.pending_output.is_empty() {
            return;
        }
        let pending = std::mem::take(&mut self.pending_output);
        let mut appended = false;
        let mut service_url_changed = false;
        for (id, text) in pending {
            let Some(session) = self.sessions.get_mut(&id) else {
                continue;
            };
            let url_before = session.service_url.clone();
            session.append_output(&text);
            appended = true;
            if url_before != session.service_url {
                service_url_changed = true;
            }
        }
        if !appended {
            return;
        }
        // 行数变化交给虚拟化列表；是否跟随末尾由 `FollowMode::Tail` 自己决定，
        // 用户上翻后框架会暂停跟随，回到底部时自动恢复，不需要再比对偏移量。
        self.sync_console_lines();
        // 顶栏只关心服务地址这类结构性变化，普通日志不惊动工作台。
        if service_url_changed {
            self.emit(cx);
        }
        cx.notify();
    }

    pub(super) fn stop_configuration(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(tree) = self
            .sessions
            .get(id)
            .and_then(|session| session.tree.clone())
        else {
            return;
        };
        if let Some(session) = self.sessions.get_mut(id) {
            session.stopped = true;
        }
        cx.background_spawn(async move {
            let _ = session::stop(tree);
        })
        .detach();
        self.emit(cx);
        cx.notify();
    }

    fn stop_all(&mut self, cx: &mut Context<Self>) {
        let trees: Vec<Arc<ProcessTree>> = self
            .sessions
            .values()
            .filter_map(|session| session.tree.clone())
            .collect();
        if trees.is_empty() {
            return;
        }
        cx.background_spawn(async move {
            for tree in trees {
                let _ = session::stop(tree);
            }
        })
        .detach();
    }

    pub(super) fn clear_output(&mut self, cx: &mut Context<Self>) {
        if let Some(id) = self.selected_id.clone() {
            if let Some(session) = self.sessions.get_mut(&id) {
                session.clear();
            }
            self.pending_output.remove(&id);
        }
        self.console.reset();
        self.console_follow_tail = true;
        self.emit(cx);
        cx.notify();
    }

    pub(super) fn emit(&self, cx: &mut Context<Self>) {
        cx.emit(RunPanelEvent::StateChanged);
    }

    /// 「仍然运行」/「对此工作区始终继续」：跳过本次构建失败继续启动。
    pub(crate) fn continue_java_launch(&mut self, always: bool, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        if always {
            if let Some(write) = self.set_java_build_policy.as_ref() {
                write(cx, &root, true);
            }
        }
        let Some(decision) = self.launch_decision.take() else {
            return;
        };
        let target = self.launch_decision_target.take();
        self.launch_configuration(
            decision.configuration,
            root,
            decision.current_file,
            target,
            cx,
        );
    }

    /// 「重建 Java 索引」：清空 JDT 工作区状态并重启语言服务，然后取消本次启动。
    pub(crate) fn rebuild_java_index(&mut self, cx: &mut Context<Self>) {
        self.launch_decision = None;
        self.launch_decision_target = None;
        self.java_language
            .update(cx, |model, cx| model.rebuild_index(cx));
        self.emit(cx);
        cx.notify();
    }

    /// 「打开日志」：取消本次启动并打开诊断设置页。
    pub(crate) fn open_decision_logs(
        &mut self,
        config_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.selected_id = Some(config_id.to_string());
        self.show_details = false;
        self.launch_decision = None;
        self.launch_decision_target = None;
        if let Some(handler) = self.on_open_settings.as_ref() {
            handler("logs", window, cx);
        }
        self.emit(cx);
        cx.notify();
    }

    /// 「取消」：取消本次启动并关闭决策横幅。
    pub(crate) fn cancel_java_launch(&mut self, cx: &mut Context<Self>) {
        self.launch_decision = None;
        self.launch_decision_target = None;
        cx.notify();
    }
}

/// 归一化 Maven 路径比较：`None` / 空串 / `.` 都视作反应堆根 `.`。
fn normalize_relative(value: Option<&str>) -> &str {
    match value {
        Some(value) if !value.trim().is_empty() && value != "." => value,
        _ => ".",
    }
}
