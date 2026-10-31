//! Maven 工具窗的树面板（右侧停靠）。
//!
//! 布局对齐 Tauri `maven-pane.tsx`：工具条 →（警告条）→ 树。
//! 树的节点结构是 Profiles / 项目 → 源码根 → 生命周期 → 依赖项 → 子模块；
//! 依赖项在展开时才调用 Core 解析（`maven.dependencyPlan` +
//! `maven.dependencies`），与 Tauri 的懒加载一致。

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use async_channel::Receiver;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Sizable as _, Size, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClickEvent, Context, DismissEvent, Div, Entity, EventEmitter,
    Focusable as _, FontWeight, InteractiveElement as _, IntoElement, ParentElement, Render,
    SharedString, Stateful, StatefulInteractiveElement as _, Styled, Subscription, Window,
    anchored, deferred, div, px, white,
};
use lithe_core_client::CoreClient;
use lithe_git_host::ProcessTree;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, current_tokens, icon};

use super::model::{
    self, Dependency, DependencyLoad, LaunchContext, MavenProject, Module, ProjectStatus,
    SourceRoot, SourceRootTone, TaskStatus,
};
use super::session::{self, SessionEvent};

/// 保留的 Maven 任务输出上限（字符）。与 Tauri `MAXIMUM_OUTPUT_CHARACTERS` 一致。
const MAX_OUTPUT_CHARACTERS: usize = 500_000;
/// 工具条高度。对齐 Tauri 的 `h-8`。
const TOOLBAR_HEIGHT: f32 = 32.0;
/// 树行高度。对齐 Tauri `min-h-7`。
const TREE_ROW_HEIGHT: f32 = 28.0;
/// 树的每一级缩进。对齐 Tauri `ml-4`。
const TREE_INDENT: f32 = 16.0;
/// 树容器内边距。
const TREE_PADDING: f32 = 8.0;
/// 工具条图标按钮尺寸，对齐其它工具窗的 22pt 动作按钮。
const TOOLBAR_BUTTON_SIZE: f32 = 22.0;
/// 弹窗宽度，与工作台输入卡片一致。
const DIALOG_WIDTH: f32 = 420.0;

type OpenLocationHandler =
    Rc<dyn Fn(PathBuf, Option<u32>, Option<u32>, &mut Window, &mut App) + 'static>;
type ActionHandler = Rc<dyn Fn(&mut Window, &mut App) + 'static>;
type RunModuleHandler = Rc<dyn Fn(&str, &str, &mut Window, &mut App) + 'static>;

/// Maven 面板状态变化。输出面板订阅它跟随重绘。
pub enum MavenPanelEvent {
    StateChanged,
}

/// Maven 工具窗。
pub struct MavenPanel {
    client: CoreClient,
    root: Option<PathBuf>,
    status: ProjectStatus,
    project: Option<MavenProject>,
    error: Option<SharedString>,
    /// 扫描代次；`set_root` / 刷新时递增，丢弃旧工作区仍在飞行中的结果。
    generation: u64,
    pending_initial_load: bool,

    // 树交互状态。
    expanded: HashSet<String>,
    /// 选中的模块路径；`None` 表示反应堆根，对齐 Tauri `selectedModule`。
    selected_module: Option<String>,
    selected_phase: &'static str,
    selected_profiles: BTreeSet<String>,
    custom_profiles: Vec<String>,
    skip_tests: bool,

    // Goal / Profile 弹窗。
    goal_dialog: Option<GoalDialog>,
    profile_dialog: Option<ProfileDialog>,

    // 依赖项懒加载：模块路径 -> 加载状态。
    dependency_loads: BTreeMap<String, DependencyLoad>,
    /// 依赖解析代次；换项目或刷新后旧结果作废。
    dependency_generation: u64,

    // 运行中的 Maven 任务。
    task: TaskState,
    /// 依赖解析进程的进程树，按模块路径索引，用于取消。
    dependency_trees: BTreeMap<String, Arc<ProcessTree>>,

    /// 右键创建的弹出菜单与其触发位置；渲染期用 `anchored` 挂到前景层。
    node_menu: Option<(Entity<PopupMenu>, gpui_kit::Point<gpui_kit::Pixels>)>,
    _menu_subscription: Option<Subscription>,

    on_open_location: Option<OpenLocationHandler>,
    on_show_output: Option<ActionHandler>,
    on_open_settings: Option<ActionHandler>,
    on_run_module: Option<RunModuleHandler>,
    on_close: Option<ActionHandler>,
}

struct GoalDialog {
    input: Entity<InputState>,
    /// 目标作用于哪个模块；`None` 表示反应堆根。
    module: Option<String>,
    _input_subscription: Subscription,
}

struct ProfileDialog {
    input: Entity<InputState>,
    _input_subscription: Subscription,
}

/// 一次 Maven 任务的全部运行时状态。
struct TaskState {
    status: TaskStatus,
    tree: Option<Arc<ProcessTree>>,
    title: Option<String>,
    output: String,
    issues: Vec<session::Diagnostic>,
    test_results: Option<session::TestResults>,
    exit_code: Option<i32>,
    error: Option<SharedString>,
    /// 测试结果只对包含 `test` 的目标解析，避免每次构建都读 surefire 报告。
    parse_test_results: bool,
}

impl TaskState {
    fn new() -> Self {
        Self {
            status: TaskStatus::Idle,
            tree: None,
            title: None,
            output: String::new(),
            issues: Vec::new(),
            test_results: None,
            exit_code: None,
            error: None,
            parse_test_results: false,
        }
    }

    fn is_idle(&self) -> bool {
        self.status == TaskStatus::Idle
    }

    fn is_running(&self) -> bool {
        matches!(self.status, TaskStatus::Running | TaskStatus::Stopping)
    }

    fn append_output(&mut self, text: &str) {
        self.output.push_str(text);
        if self.output.len() > MAX_OUTPUT_CHARACTERS {
            let cut = self.output.len() - MAX_OUTPUT_CHARACTERS;
            // 只在换行处截断，避免把一行日志切成两半。
            let boundary = self.output[cut..]
                .find('\n')
                .map(|offset| cut + offset + 1)
                .unwrap_or(self.output.len());
            self.output.drain(..boundary);
        }
    }
}

impl EventEmitter<MavenPanelEvent> for MavenPanel {}

impl MavenPanel {
    pub fn new(
        client: CoreClient,
        root: PathBuf,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Self {
        // 路径无效时保持「未打开项目」状态，不立刻报错；打开有效项目时会再走 set_root。
        let root = normalize_root(root);
        Self {
            pending_initial_load: root.is_some(),
            client,
            root,
            status: ProjectStatus::Idle,
            project: None,
            error: None,
            generation: 0,
            expanded: HashSet::new(),
            selected_module: None,
            selected_phase: model::DEFAULT_PHASE,
            selected_profiles: BTreeSet::new(),
            custom_profiles: Vec::new(),
            skip_tests: false,
            goal_dialog: None,
            profile_dialog: None,
            dependency_loads: BTreeMap::new(),
            dependency_generation: 0,
            task: TaskState::new(),
            dependency_trees: BTreeMap::new(),
            node_menu: None,
            _menu_subscription: None,
            on_open_location: None,
            on_show_output: None,
            on_open_settings: None,
            on_run_module: None,
            on_close: None,
        }
    }

    pub fn on_open_location(
        &mut self,
        handler: impl Fn(PathBuf, Option<u32>, Option<u32>, &mut Window, &mut App) + 'static,
    ) {
        self.on_open_location = Some(Rc::new(handler));
    }

    pub fn on_show_output(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_show_output = Some(Rc::new(handler));
    }

    pub fn on_open_settings(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_open_settings = Some(Rc::new(handler));
    }

    pub fn on_run_module(&mut self, handler: impl Fn(&str, &str, &mut Window, &mut App) + 'static) {
        self.on_run_module = Some(Rc::new(handler));
    }

    /// 标题行关闭按钮；由工作台隐藏右侧停靠区。
    pub fn on_close(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_close = Some(Rc::new(handler));
    }

    /// 切换项目根目录；旧任务先停止，旧扫描与依赖结果全部作废。
    pub fn set_root(&mut self, root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        self.stop_task(cx);
        self.root = normalize_root(root);
        self.generation = self.generation.wrapping_add(1);
        self.dependency_generation = self.dependency_generation.wrapping_add(1);
        self.status = ProjectStatus::Idle;
        self.project = None;
        self.error = None;
        self.expanded.clear();
        self.selected_module = None;
        self.selected_phase = model::DEFAULT_PHASE;
        self.selected_profiles.clear();
        self.custom_profiles.clear();
        self.dependency_loads.clear();
        self.dependency_trees.clear();
        self.goal_dialog = None;
        self.profile_dialog = None;
        self.node_menu = None;
        self._menu_subscription = None;
        self.task = TaskState::new();
        self.pending_initial_load = self.root.is_some();
        self.emit_changed(cx);
        cx.notify();
    }

    /// 重新扫描 Maven 项目。工具条刷新按钮与节点菜单的 Reload 共用。
    pub fn refresh(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        self.load_project(cx);
    }

    // -----------------------------------------------------------------------
    // 项目扫描
    // -----------------------------------------------------------------------

    fn load_project(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        self.status = ProjectStatus::Loading;
        self.error = None;
        self.emit_changed(cx);
        cx.notify();

        let generation = self.generation;
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let scan = cx
                .background_spawn(async move {
                    // Core 找不到可读 pom.xml 时 data 为 null，映射成 None。
                    client
                        .execute_raw(
                            "maven.scan",
                            serde_json::json!({ "root": root_text(&root) }),
                        )
                        .map(|data| MavenProject::from_json(&data))
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.status = ProjectStatus::Ready;
                match scan {
                    Ok(Some(project)) => {
                        this.project = Some(project);
                        this.error = None;
                        this.apply_default_expansion();
                    }
                    Ok(None) => {
                        this.project = None;
                        this.error = None;
                    }
                    Err(error) => {
                        this.project = None;
                        this.error = Some(error.to_string().into());
                    }
                }
                this.emit_changed(cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// 扫描成功后的默认展开与选中，对齐 Tauri：展开项目与 Profiles。
    fn apply_default_expansion(&mut self) {
        let Some(project) = self.project.as_ref() else {
            return;
        };
        self.expanded
            .insert(format!("project:{}", project.relative_path));
        if !project.profiles.is_empty() || !self.custom_profiles.is_empty() {
            self.expanded.insert("profiles".to_string());
        }
        // activeByDefault 的 Profile 默认勾选。
        for profile in &project.profiles {
            if profile.is_active_by_default {
                self.selected_profiles.insert(profile.id.clone());
            }
        }
        self.selected_module = None;
        self.selected_phase = model::DEFAULT_PHASE;
    }

    // -----------------------------------------------------------------------
    // 生命周期与 Goal 执行
    // -----------------------------------------------------------------------

    /// 当前启动上下文。本构建没有 Maven 设置存储，settings / 本地仓库 /
    /// 可执行文件路径都交给 Core 与宿主解析器按默认规则处理。
    fn launch_context(&self) -> Option<LaunchContext> {
        let project = self.project.as_ref()?;
        Some(LaunchContext {
            reactor_path: project.relative_path.clone(),
            profiles: self.selected_profiles.iter().cloned().collect(),
            settings_path: None,
            local_repository_path: None,
            skip_tests: self.skip_tests,
            maven_executable_path: None,
            java_home_path: None,
        })
    }

    /// 工具条 Run：运行选中模块上的选中生命周期阶段。
    pub fn run_selected(&mut self, cx: &mut Context<Self>) {
        let module = self.selected_module.clone();
        let phase = self.selected_phase;
        self.run_goals(vec![phase.to_string()], module, phase.to_string(), cx);
    }

    /// 运行一组 Maven 目标。上下文菜单的 Test / Package 与 Goal 弹窗共用。
    pub fn run_goals(
        &mut self,
        goals: Vec<String>,
        module: Option<String>,
        title: String,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(context) = self.launch_context() else {
            return;
        };
        if goals.is_empty() {
            return;
        }
        // 已有任务在跑时先停掉：Tauri 的 runGoals 同样先 stop 再启动。
        self.stop_task(cx);

        let parse_test_results = goals.iter().any(|goal| goal.contains("test"));
        self.task = TaskState {
            status: TaskStatus::Running,
            title: Some(title),
            parse_test_results,
            ..TaskState::new()
        };
        self.emit_changed(cx);
        cx.notify();

        let generation = self.generation;
        let client = self.client;
        cx.spawn(async move |this, cx| {
            // 对齐 Tauri `runPhase` / `runCustomGoal` / `runModuleGoal`：运行前先
            // 打开底部 Maven 输出面板，日志从这里实时滚动；不打开的话用户只能
            // 在任务结束后看到错误条，看不到任何输出。
            let _ = this.update_in(cx, |this, window, cx| {
                if let Some(handler) = this.on_show_output.clone() {
                    handler(window, cx);
                }
            });
            let launched = cx
                .background_spawn(async move {
                    session::plan_goal(client, &root, &context, module.as_deref(), &goals)
                })
                .await;
            match launched {
                Ok(launch) => {
                    let header = format!(
                        "$ {} {}\n\n",
                        launch.executable_name(),
                        launch.display_arguments()
                    );
                    let receiver = session::spawn(launch);
                    let _ = this.update(cx, |this, cx| {
                        this.task.output.push_str(&header);
                        this.emit_changed(cx);
                        this.watch_task(receiver, generation, cx);
                    });
                }
                Err(error) => {
                    let _ = this.update(cx, |this, cx| {
                        if this.generation == generation {
                            this.task.status = TaskStatus::Failed;
                            this.task.exit_code = Some(1);
                            this.task.error = Some(error.into());
                            this.emit_changed(cx);
                            cx.notify();
                        }
                    });
                }
            }
        })
        .detach();
    }

    fn watch_task(
        &mut self,
        receiver: Receiver<SessionEvent>,
        generation: u64,
        cx: &mut Context<Self>,
    ) {
        cx.spawn(async move |this, cx| {
            while let Ok(event) = receiver.recv().await {
                let keep = this
                    .update(cx, |this, cx| this.handle_task_event(event, generation, cx))
                    .unwrap_or(false);
                if !keep {
                    break;
                }
            }
        })
        .detach();
    }

    fn handle_task_event(
        &mut self,
        event: SessionEvent,
        generation: u64,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.generation != generation {
            return false;
        }
        match event {
            SessionEvent::Started(tree) => {
                self.task.tree = Some(tree);
            }
            SessionEvent::Output(text) => {
                self.task.append_output(&text);
                self.emit_changed(cx);
                cx.notify();
                return true;
            }
            SessionEvent::Exited(code) => {
                self.task.tree = None;
                self.task.exit_code = code;
                self.task.status = TaskStatus::Idle;
                if code.is_some_and(|code| code != 0) {
                    self.task.error = Some(
                        tr("Maven exited with code {code}.")
                            .replace("{code}", &code.unwrap_or(0).to_string())
                            .into(),
                    );
                }
                self.parse_task_results(cx);
            }
            SessionEvent::Failed(message) => {
                self.task.tree = None;
                self.task.status = TaskStatus::Failed;
                self.task.exit_code = Some(1);
                self.task.error = Some(message.into());
            }
        }
        self.emit_changed(cx);
        cx.notify();
        true
    }

    /// 任务结束后把整段输出交给 Core 解析诊断；测试目标再解析测试结果。
    fn parse_task_results(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let output = self.task.output.clone();
        let parse_test_results = self.task.parse_test_results;
        let generation = self.generation;
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let diagnostics = cx
                .background_spawn(async move {
                    session::parse_diagnostics(client, &root, &output).unwrap_or_default()
                })
                .await;
            let Some(root) = this.update(cx, |this, _| this.root.clone()).ok().flatten() else {
                return;
            };
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.task.issues = diagnostics;
                this.emit_changed(cx);
                cx.notify();
            });
            if !parse_test_results {
                return;
            }
            let output = this
                .update(cx, |this, _| this.task.output.clone())
                .unwrap_or_default();
            let results = cx
                .background_spawn(async move {
                    session::parse_test_results(client, &root, &output)
                        .ok()
                        .flatten()
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.task.test_results = results;
                this.emit_changed(cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// 停止当前 Maven 任务。真正等待进程退出的是会话线程；这里只发出请求。
    pub fn stop_task(&mut self, cx: &mut Context<Self>) {
        let Some(tree) = self.task.tree.take() else {
            return;
        };
        self.task.status = TaskStatus::Stopping;
        self.task
            .output
            .push_str(&cancelled_output(&self.task.output));
        self.emit_changed(cx);
        cx.notify();
        cx.spawn(async move |this, cx| {
            let _ = cx
                .background_spawn(async move { session::stop(tree) })
                .await;
            let _ = this.update(cx, |_, _| {});
        })
        .detach();
    }

    pub fn clear_output(&mut self, cx: &mut Context<Self>) {
        if self.task.is_running() {
            return;
        }
        self.task.output.clear();
        self.task.issues.clear();
        self.task.test_results = None;
        self.task.exit_code = None;
        self.task.error = None;
        self.task.status = TaskStatus::Idle;
        self.emit_changed(cx);
        cx.notify();
    }

    // -----------------------------------------------------------------------
    // 依赖项懒加载
    // -----------------------------------------------------------------------

    /// 展开依赖项分组时解析该模块的依赖树。
    fn load_dependencies(&mut self, module_path: String, cx: &mut Context<Self>) {
        if self
            .dependency_loads
            .get(&module_path)
            .is_some_and(DependencyLoad::is_loading)
        {
            return;
        }
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(context) = self.launch_context() else {
            return;
        };
        // Core 要求依赖树写进一个平台文件；用临时目录里的会话级文件，读完后删除。
        self.dependency_generation = self.dependency_generation.wrapping_add(1);
        let output_file = std::env::temp_dir().join(format!(
            "lithe-maven-deps-{}-{}.txt",
            std::process::id(),
            self.dependency_generation
        ));
        self.dependency_loads
            .insert(module_path.clone(), DependencyLoad::Loading);
        self.emit_changed(cx);
        cx.notify();

        let generation = self.generation;
        let dependency_generation = self.dependency_generation;
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let planned_module = module_path.clone();
            let planned_output = output_file.clone();
            let planned = cx
                .background_spawn(async move {
                    session::plan_dependency_tree(
                        client,
                        &root,
                        &context,
                        Some(&planned_module),
                        &planned_output,
                    )
                })
                .await;
            match planned {
                Ok(launch) => {
                    let receiver = session::spawn(launch);
                    let _ = this.update(cx, |this, cx| {
                        this.watch_dependency_session(
                            receiver,
                            module_path.clone(),
                            output_file.clone(),
                            generation,
                            dependency_generation,
                            cx,
                        );
                    });
                }
                Err(error) => {
                    let _ = this.update(cx, |this, cx| {
                        if this.generation != generation {
                            return;
                        }
                        this.dependency_loads
                            .insert(module_path.clone(), DependencyLoad::Failed(error));
                        this.emit_changed(cx);
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    #[allow(clippy::too_many_arguments)]
    fn watch_dependency_session(
        &mut self,
        receiver: Receiver<SessionEvent>,
        module_path: String,
        output_file: PathBuf,
        generation: u64,
        dependency_generation: u64,
        cx: &mut Context<Self>,
    ) {
        cx.spawn(async move |this, cx| {
            while let Ok(event) = receiver.recv().await {
                match event {
                    SessionEvent::Started(tree) => {
                        let _ = this.update(cx, |this, _| {
                            this.dependency_trees.insert(module_path.clone(), tree);
                        });
                    }
                    // 依赖解析是静默后台过程：不把输出展示给用户，只等退出码。
                    SessionEvent::Output(_) => {}
                    SessionEvent::Exited(code) => {
                        let _ = this.update(cx, |this, cx| {
                            this.dependency_trees.remove(&module_path);
                            if this.generation != generation {
                                return;
                            }
                            if code == Some(0) {
                                this.finish_dependency_load(
                                    module_path.clone(),
                                    output_file.clone(),
                                    generation,
                                    dependency_generation,
                                    cx,
                                );
                            } else {
                                this.dependency_loads.insert(
                                    module_path.clone(),
                                    DependencyLoad::Failed(
                                        tr("Maven dependency resolution exited with code {code}.")
                                            .replace("{code}", &code.unwrap_or(0).to_string())
                                            .into(),
                                    ),
                                );
                                this.emit_changed(cx);
                                cx.notify();
                            }
                        });
                        break;
                    }
                    SessionEvent::Failed(message) => {
                        let _ = this.update(cx, |this, cx| {
                            this.dependency_trees.remove(&module_path);
                            if this.generation == generation {
                                this.dependency_loads
                                    .insert(module_path.clone(), DependencyLoad::Failed(message));
                                this.emit_changed(cx);
                                cx.notify();
                            }
                        });
                        break;
                    }
                }
            }
        })
        .detach();
    }

    /// 进程成功退出后读取 Core 写出的依赖树文件。
    fn finish_dependency_load(
        &mut self,
        module_path: String,
        output_file: PathBuf,
        generation: u64,
        dependency_generation: u64,
        cx: &mut Context<Self>,
    ) {
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let read_module = module_path.clone();
            let read_output = output_file.clone();
            let loaded = cx
                .background_spawn(async move {
                    session::read_dependencies(client, &read_module, &read_output)
                })
                .await;
            let _ = std::fs::remove_file(&output_file);
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation
                    || this.dependency_generation != dependency_generation
                {
                    return;
                }
                match loaded {
                    Ok(dependencies) => {
                        this.dependency_loads
                            .insert(module_path.clone(), DependencyLoad::Ready(dependencies));
                    }
                    Err(error) => {
                        this.dependency_loads
                            .insert(module_path.clone(), DependencyLoad::Failed(error));
                    }
                }
                this.emit_changed(cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// 取消进行中的依赖解析。
    fn cancel_dependency_load(&mut self, module_path: &str, cx: &mut Context<Self>) {
        let Some(tree) = self.dependency_trees.remove(module_path) else {
            return;
        };
        self.dependency_loads
            .insert(module_path.to_string(), DependencyLoad::Cancelled);
        self.emit_changed(cx);
        cx.notify();
        cx.spawn(async move |this, cx| {
            let _ = cx
                .background_spawn(async move { session::stop(tree) })
                .await;
            let _ = this.update(cx, |_, _| {});
        })
        .detach();
    }

    // -----------------------------------------------------------------------
    // Profiles
    // -----------------------------------------------------------------------

    pub fn toggle_profile(&mut self, id: String, cx: &mut Context<Self>) {
        if !self.selected_profiles.remove(&id) {
            self.selected_profiles.insert(id);
        }
        self.emit_changed(cx);
        cx.notify();
    }

    pub fn restore_default_profiles(&mut self, cx: &mut Context<Self>) {
        self.custom_profiles.clear();
        self.selected_profiles.clear();
        if let Some(project) = self.project.as_ref() {
            for profile in &project.profiles {
                if profile.is_active_by_default {
                    self.selected_profiles.insert(profile.id.clone());
                }
            }
        }
        self.emit_changed(cx);
        cx.notify();
    }

    pub fn add_custom_profile(&mut self, id: String, cx: &mut Context<Self>) {
        let id = id.trim().to_string();
        if id.is_empty() {
            return;
        }
        if !self.custom_profiles.contains(&id) {
            self.custom_profiles.push(id.clone());
        }
        self.selected_profiles.insert(id);
        self.expanded.insert("profiles".to_string());
        self.emit_changed(cx);
        cx.notify();
    }

    pub fn set_skip_tests(&mut self, skip: bool, cx: &mut Context<Self>) {
        self.skip_tests = skip;
        self.emit_changed(cx);
        cx.notify();
    }

    // -----------------------------------------------------------------------
    // 树交互
    // -----------------------------------------------------------------------

    pub fn collapse_all(&mut self, cx: &mut Context<Self>) {
        self.expanded.clear();
        cx.notify();
    }

    fn toggle_expanded(&mut self, id: &str, cx: &mut Context<Self>) {
        if !self.expanded.remove(id) {
            self.expanded.insert(id.to_string());
            // 展开依赖项分组时才解析依赖，对齐 Tauri 的懒加载。
            if let Some(owner) = id.strip_suffix(":dependencies") {
                let module_path = owner_module_path(owner);
                self.load_dependencies(module_path, cx);
            }
        }
        cx.notify();
    }

    fn select_module(&mut self, module: Option<String>, cx: &mut Context<Self>) {
        self.selected_module = module;
        cx.notify();
    }

    fn select_phase(
        &mut self,
        module: Option<String>,
        phase: &'static str,
        cx: &mut Context<Self>,
    ) {
        self.selected_module = module;
        self.selected_phase = phase;
        cx.notify();
    }

    fn open_pom(&mut self, module_path: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(project) = self.project.as_ref() else {
            return;
        };
        // 模块路径是反应堆相对的；先叠加反应堆根，再拼 pom.xml。
        let mut relative = PathBuf::new();
        if project.relative_path != "." {
            relative.push(
                project
                    .relative_path
                    .replace('/', std::path::MAIN_SEPARATOR_STR),
            );
        }
        if module_path != "." {
            relative.push(module_path.replace('/', std::path::MAIN_SEPARATOR_STR));
        }
        relative.push("pom.xml");
        let absolute = root.join(relative);
        if let Some(handler) = self.on_open_location.clone() {
            handler(absolute, None, None, window, cx);
        }
    }

    fn run_module_configuration(
        &mut self,
        module_path: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(project) = self.project.as_ref() else {
            return;
        };
        let reactor = project.relative_path.clone();
        let module = module_path.to_string();
        if let Some(handler) = self.on_run_module.clone() {
            handler(&reactor, &module, window, cx);
        }
    }

    // -----------------------------------------------------------------------
    // 弹窗
    // -----------------------------------------------------------------------

    fn open_goal_dialog(
        &mut self,
        module: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let input = cx.new(|input_cx| {
            InputState::new(window, input_cx).placeholder(SharedString::from("spring-boot:run"))
        });
        let subscription = cx.subscribe(&input, |this, _, event: &InputEvent, cx| {
            if matches!(
                event,
                InputEvent::PressEnter {
                    secondary: false,
                    shift: false,
                }
            ) {
                this.confirm_goal_dialog(cx);
            }
        });
        self.goal_dialog = Some(GoalDialog {
            input: input.clone(),
            module,
            _input_subscription: subscription,
        });
        input.update(cx, |state, cx| state.focus(window, cx));
        cx.notify();
    }

    fn close_goal_dialog(&mut self, cx: &mut Context<Self>) {
        self.goal_dialog = None;
        cx.notify();
    }

    fn confirm_goal_dialog(&mut self, cx: &mut Context<Self>) {
        let Some(dialog) = self.goal_dialog.take() else {
            return;
        };
        let goal = dialog.input.read(cx).value().trim().to_string();
        if goal.is_empty() {
            self.goal_dialog = Some(dialog);
            return;
        }
        // 自定义 Goal 允许带参数（例如 `spring-boot:run -DskipTests`）；Core 的
        // goals 数组第一个元素是 Goal，其余是参数，这里按空格拆开交给它校验。
        let parts: Vec<String> = goal.split_whitespace().map(str::to_string).collect();
        self.run_goals(parts, dialog.module.clone(), goal, cx);
        cx.notify();
    }

    fn open_profile_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let input =
            cx.new(|input_cx| InputState::new(window, input_cx).placeholder(tr("Profile ID")));
        let subscription = cx.subscribe(&input, |this, _, event: &InputEvent, cx| {
            if matches!(
                event,
                InputEvent::PressEnter {
                    secondary: false,
                    shift: false,
                }
            ) {
                this.confirm_profile_dialog(cx);
            }
        });
        self.profile_dialog = Some(ProfileDialog {
            input: input.clone(),
            _input_subscription: subscription,
        });
        input.update(cx, |state, cx| state.focus(window, cx));
        cx.notify();
    }

    fn close_profile_dialog(&mut self, cx: &mut Context<Self>) {
        self.profile_dialog = None;
        cx.notify();
    }

    fn confirm_profile_dialog(&mut self, cx: &mut Context<Self>) {
        let Some(dialog) = self.profile_dialog.take() else {
            return;
        };
        let id = dialog.input.read(cx).value().trim().to_string();
        if id.is_empty() {
            self.profile_dialog = Some(dialog);
            return;
        }
        self.add_custom_profile(id, cx);
    }

    /// 面板内的模态输入弹窗（Goal / Profile 共用卡片结构）。
    fn render_dialogs(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (title, confirm_label, dialog_id) = if self.goal_dialog.is_some() {
            (tr("Execute Maven goal"), tr("Run"), "goal")
        } else if self.profile_dialog.is_some() {
            (tr("Add Maven profile"), tr("Add"), "profile")
        } else {
            return None;
        };
        let input = if dialog_id == "goal" {
            self.goal_dialog.as_ref().map(|dialog| dialog.input.clone())
        } else {
            self.profile_dialog
                .as_ref()
                .map(|dialog| dialog.input.clone())
        }
        .expect("dialog state must exist when rendering a dialog");
        let value = input.read(cx).value().trim().is_empty();

        let overlay = div()
            .id("lithe-maven-dialog")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    // 点击遮罩关闭：与工作台输入卡片一致。
                    if this.goal_dialog.is_some() {
                        this.close_goal_dialog(cx);
                    } else if this.profile_dialog.is_some() {
                        this.close_profile_dialog(cx);
                    }
                }),
            )
            .child(
                div()
                    .occlude()
                    .flex()
                    .flex_col()
                    .w(px(DIALOG_WIDTH))
                    .rounded(px(LitheMetrics::PANE_RADIUS))
                    .overflow_hidden()
                    .bg(tokens.raised)
                    .border_1()
                    .border_color(tokens.panel_border)
                    .p(px(16.0))
                    .gap(px(10.0))
                    .child(
                        div()
                            .w_full()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(tokens.primary_text)
                            .child(title),
                    )
                    .child(Input::new(&input).w_full()),
            )
            .child(
                h_flex()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        Button::new(SharedString::from(format!(
                            "lithe-maven-dialog:{dialog_id}:cancel"
                        )))
                        .ghost()
                        .small()
                        .tab_stop(false)
                        .label(tr("Cancel"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            if this.goal_dialog.is_some() {
                                this.close_goal_dialog(cx);
                            } else {
                                this.close_profile_dialog(cx);
                            }
                        })),
                    )
                    .child(
                        Button::new(SharedString::from(format!(
                            "lithe-maven-dialog:{dialog_id}:confirm"
                        )))
                        .primary()
                        .small()
                        .tab_stop(false)
                        .disabled(value)
                        .label(confirm_label)
                        .on_click(cx.listener(|this, _, _, cx| {
                            if this.goal_dialog.is_some() {
                                this.confirm_goal_dialog(cx);
                            } else {
                                this.confirm_profile_dialog(cx);
                            }
                        })),
                    ),
            )
            .into_any_element();
        Some(overlay)
    }

    // -----------------------------------------------------------------------
    // 节点菜单
    // -----------------------------------------------------------------------

    fn open_node_menu(
        &mut self,
        module: Option<String>,
        module_path: String,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let busy = self.task.is_running();
        let owner = cx.weak_entity();
        let popup =
            PopupMenu::build(window, cx, move |menu, _window, _cx| {
                let module_for_run = module_path.clone();
                let module_for_test = module_path.clone();
                let module_for_package = module_path.clone();
                let module_for_goal = module.clone();
                let module_for_pom = module_path.clone();
                // 每个条目的闭包各自持有一份弱引用，不能共享同一个 move 值。
                let owner_for_run = owner.clone();
                let owner_for_test = owner.clone();
                let owner_for_package = owner.clone();
                let owner_for_goal = owner.clone();
                let owner_for_pom = owner.clone();
                let owner_for_reload = owner.clone();
                menu.min_w(px(220.0))
                    .item(PopupMenuItem::new(tr("Run")).disabled(busy).on_click(
                        move |_, window, cx| {
                            let _ = owner_for_run.update(cx, |this, cx| {
                                this.run_module_configuration(&module_for_run.clone(), window, cx);
                            });
                        },
                    ))
                    // GPUI 构建没有 DAP 传输层，Debug 保持禁用并只展示入口。
                    .item(
                        PopupMenuItem::new(tr("Debug"))
                            .disabled(true)
                            .on_click(|_, _, _| {}),
                    )
                    .separator()
                    .item(PopupMenuItem::new(tr("Test")).disabled(busy).on_click(
                        move |_, _, cx| {
                            let _ = owner_for_test.update(cx, |this, cx| {
                                let module = module_for_test.clone();
                                this.run_goals(
                                    vec!["test".to_string()],
                                    Some(module),
                                    tr("Test").to_string(),
                                    cx,
                                );
                            });
                        },
                    ))
                    .item(PopupMenuItem::new(tr("Package")).disabled(busy).on_click(
                        move |_, _, cx| {
                            let _ = owner_for_package.update(cx, |this, cx| {
                                let module = module_for_package.clone();
                                this.run_goals(
                                    vec!["package".to_string()],
                                    Some(module),
                                    tr("Package").to_string(),
                                    cx,
                                );
                            });
                        },
                    ))
                    .item(
                        PopupMenuItem::new(tr("Execute Maven goal"))
                            .disabled(busy)
                            .on_click(move |_, window, cx| {
                                let _ = owner_for_goal.update(cx, |this, cx| {
                                    let module = module_for_goal.clone();
                                    this.open_goal_dialog(module, window, cx);
                                });
                            }),
                    )
                    .separator()
                    .item(
                        PopupMenuItem::new(tr("Open pom.xml")).on_click(move |_, window, cx| {
                            let _ = owner_for_pom.update(cx, |this, cx| {
                                let module = module_for_pom.clone();
                                this.open_pom(&module, window, cx);
                            });
                        }),
                    )
                    .item(PopupMenuItem::new(tr("Reload Maven projects")).on_click(
                        move |_, _, cx| {
                            let _ = owner_for_reload.update(cx, |this, cx| this.load_project(cx));
                        },
                    ))
            });
        let subscription =
            cx.subscribe_in(&popup, window, |this, _, _: &DismissEvent, _window, cx| {
                this.node_menu = None;
                this._menu_subscription = None;
                cx.notify();
            });
        let focus_handle = popup.read(cx).focus_handle(cx);
        if !focus_handle.contains_focused(window, cx) {
            focus_handle.focus(window, cx);
        }
        self.node_menu = Some((popup, position));
        self._menu_subscription = Some(subscription);
        cx.notify();
    }

    fn show_popup(
        &mut self,
        popup: Entity<PopupMenu>,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let subscription =
            cx.subscribe_in(&popup, window, |this, _, _: &DismissEvent, _window, cx| {
                this.node_menu = None;
                this._menu_subscription = None;
                cx.notify();
            });
        let focus_handle = popup.read(cx).focus_handle(cx);
        if !focus_handle.contains_focused(window, cx) {
            focus_handle.focus(window, cx);
        }
        self.node_menu = Some((popup, position));
        self._menu_subscription = Some(subscription);
        cx.notify();
    }

    fn emit_changed(&self, cx: &mut Context<Self>) {
        cx.emit(MavenPanelEvent::StateChanged);
    }

    // -----------------------------------------------------------------------
    // 输出面板访问器
    // -----------------------------------------------------------------------

    pub fn task_status(&self) -> TaskStatus {
        self.task.status
    }

    pub fn task_title(&self) -> Option<&str> {
        self.task.title.as_deref()
    }

    pub fn task_error(&self) -> Option<&str> {
        self.task.error.as_deref()
    }

    pub fn task_output(&self) -> &str {
        &self.task.output
    }

    pub fn task_line_count(&self) -> usize {
        self.task.output.lines().count()
    }

    pub fn task_line_at(&self, index: usize) -> &str {
        self.task.output.lines().nth(index).unwrap_or("")
    }

    pub fn task_exit_code(&self) -> Option<i32> {
        self.task.exit_code
    }

    pub fn task_issues(&self) -> &[session::Diagnostic] {
        &self.task.issues
    }

    pub fn task_test_results(&self) -> Option<&session::TestResults> {
        self.task.test_results.as_ref()
    }

    pub fn has_maven_output(&self) -> bool {
        !self.task.is_idle()
            || self.task.title.is_some()
            || self.task.error.is_some()
            || !self.task.output.is_empty()
            || !self.task.issues.is_empty()
            || self.task.exit_code.is_some()
    }

    /// 把诊断 / 测试失败里的路径解析成绝对路径。
    ///
    /// Core 的诊断 path 可能是绝对路径；工作区相对路径与根拼接。
    pub fn resolve_path(&self, path: &str) -> PathBuf {
        let candidate = PathBuf::from(path);
        if candidate.is_absolute() {
            candidate
        } else {
            self.root.clone().unwrap_or_default().join(path)
        }
    }
}

impl Render for MavenPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.pending_initial_load {
            self.pending_initial_load = false;
            cx.defer_in(window, |this, _window, cx| {
                this.load_project(cx);
            });
        }

        let tokens = current_tokens(cx);
        let mut panel = v_flex()
            .id("lithe-maven-panel")
            .size_full()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .relative()
            .overflow_hidden()
            .bg(tokens.editor)
            .text_color(tokens.primary_text)
            .child(self.render_title_row(tokens, cx))
            .child(self.render_toolbar(tokens, cx));

        if let Some(warning) = self.render_warning(tokens) {
            panel = panel.child(warning);
        }

        panel = panel.child(
            div()
                .flex_1()
                .min_h(px(0.0))
                .min_w(px(0.0))
                .overflow_hidden()
                .child(self.render_body(tokens, cx)),
        );

        if let Some(dialog) = self.render_dialogs(tokens, cx) {
            panel = panel.child(dialog);
        }

        self.with_floating_menu(panel.into_any_element(), cx)
    }
}

impl MavenPanel {
    /// 把右键创建的 PopupMenu 渲染到窗口前景层。
    ///
    /// 之前菜单实体只创建不渲染，模块右键菜单从未显示过。
    fn with_floating_menu(&self, element: AnyElement, cx: &mut Context<Self>) -> AnyElement {
        let Some((popup, position)) = &self.node_menu else {
            return element;
        };
        let owner = cx.weak_entity();
        deferred(
            anchored().position(*position).snap_to_window().child(
                div()
                    .occlude()
                    .on_mouse_down_out(cx.listener(move |this, _, _, cx| {
                        if this.node_menu.take().is_some() {
                            cx.notify();
                        }
                    }))
                    .child(popup.clone()),
            ),
        )
        .into_any_element()
    }
}

impl MavenPanel {
    // -----------------------------------------------------------------------
    // 渲染
    // -----------------------------------------------------------------------

    /// 32pt 标题行：Maven 图标 + `Maven · <artifactId>` + 扫描 Spinner + 关闭。
    fn render_title_row(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let title = match self.project.as_ref() {
            Some(project) => {
                SharedString::from(format!("{} · {}", tr("Maven"), project.artifact_id))
            }
            None => SharedString::from(tr("Maven")),
        };
        let mut row = h_flex()
            .h(px(TOOLBAR_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(8.0))
            .pl(px(12.0))
            .pr(px(6.0))
            .child(
                icon(LitheIcon::Maven)
                    .with_size(px(16.0))
                    .text_color(tokens.accent),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .flex_shrink_1()
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.primary_text)
                    .child(title),
            );
        if self.status == ProjectStatus::Loading {
            row = row.child(
                Spinner::new()
                    .with_size(Size::XSmall)
                    .color(tokens.secondary_text),
            );
        }
        row = row.child(div().flex_1()).child(
            Button::new("lithe-maven:close")
                .ghost()
                .with_size(px(TOOLBAR_BUTTON_SIZE))
                .rounded(px(LitheMetrics::CONTROL_RADIUS))
                .icon(icon(LitheIcon::Close))
                .tooltip(tr("Close"))
                .accessibility_label(tr("Close"))
                .on_click(cx.listener(|this, _, window, cx| {
                    if let Some(handler) = this.on_close.clone() {
                        handler(window, cx);
                    }
                })),
        );
        row.into_any_element()
    }

    /// 32pt 动作工具条。按钮顺序与图标对齐 Tauri `maven-pane` 工具条：
    /// Run/Stop → 执行 Goal → 构建输出 → 重新加载 → 跳过测试 → 全部折叠 → 设置。
    fn render_toolbar(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let busy = self.task.is_running();
        let has_project = self.project.is_some();
        let run_label = if busy {
            tr("Stop Maven task")
        } else {
            tr("Run selected lifecycle phase")
        };
        let run_icon = if busy {
            icon(LitheIcon::Stop)
        } else {
            icon(LitheIcon::Run)
        };
        let run_color = if busy { tokens.warning } else { tokens.success };

        let toolbar = h_flex()
            .h(px(TOOLBAR_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(2.0))
            .px(px(8.0))
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                Button::new("lithe-maven:run")
                    .ghost()
                    .with_size(px(TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(run_icon.text_color(run_color))
                    .tooltip(run_label)
                    .accessibility_label(run_label)
                    .disabled(!has_project)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if this.task.is_running() {
                            this.stop_task(cx);
                        } else {
                            this.run_selected(cx);
                        }
                    })),
            )
            .child(
                Button::new("lithe-maven:goal")
                    .ghost()
                    .with_size(px(TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(icon(LitheIcon::Terminal))
                    .tooltip(tr("Execute Maven goal"))
                    .accessibility_label(tr("Execute Maven goal"))
                    .disabled(!has_project || busy)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        let module = this.selected_module.clone();
                        this.open_goal_dialog(module, window, cx);
                    })),
            )
            .child(
                Button::new("lithe-maven:output")
                    .ghost()
                    .with_size(px(TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(icon(LitheIcon::BuildOutput))
                    .tooltip(tr("Build Output"))
                    .accessibility_label(tr("Build Output"))
                    .disabled(!self.has_maven_output())
                    .on_click(cx.listener(|this, _, window, cx| {
                        if let Some(handler) = this.on_show_output.clone() {
                            handler(window, cx);
                        }
                    })),
            )
            .child(
                Button::new("lithe-maven:reload")
                    .ghost()
                    .with_size(px(TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(icon(LitheIcon::Refresh))
                    .tooltip(tr("Reload Maven projects"))
                    .accessibility_label(tr("Reload Maven projects"))
                    .disabled(self.root.is_none() || busy || self.status == ProjectStatus::Loading)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.refresh(window, cx);
                    })),
            )
            .child(
                div().mx(px(4.0)).child(
                    Checkbox::new("lithe-maven:skip-tests")
                        .small()
                        .checked(self.skip_tests)
                        .disabled(!has_project)
                        .on_change(cx.listener(|this, checked: &bool, _, cx| {
                            this.set_skip_tests(*checked, cx);
                        })),
                ),
            )
            .child(
                Button::new("lithe-maven:collapse")
                    .ghost()
                    .with_size(px(TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(icon(LitheIcon::CollapseAll))
                    .tooltip(tr("Collapse all"))
                    .accessibility_label(tr("Collapse all"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.collapse_all(cx);
                    })),
            )
            .child(
                Button::new("lithe-maven:settings")
                    .ghost()
                    .with_size(px(TOOLBAR_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(icon(LitheIcon::Sliders))
                    .tooltip(tr("Maven Settings"))
                    .accessibility_label(tr("Maven Settings"))
                    .disabled(!has_project)
                    .on_click(cx.listener(|this, _, window, cx| {
                        if let Some(handler) = this.on_open_settings.clone() {
                            handler(window, cx);
                        }
                    })),
            );
        toolbar.into_any_element()
    }

    /// 警告条：扫描失败等原因。Tauri 的多条优先级在这里收敛成一条。
    fn render_warning(&self, tokens: LitheTokens) -> Option<AnyElement> {
        let message: SharedString = self.error.clone()?;
        Some(
            h_flex()
                .w_full()
                .flex_shrink_0()
                .min_h(px(36.0))
                .items_center()
                .gap(px(8.0))
                .px(px(12.0))
                .bg(tokens.warning.alpha(0.10))
                .border_b_1()
                .border_color(tokens.divider)
                .child(
                    icon(LitheIcon::Warning)
                        .with_size(px(14.0))
                        .text_color(tokens.warning),
                )
                .child(
                    div()
                        .min_w(px(0.0))
                        .truncate()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(message),
                )
                .into_any_element(),
        )
    }

    fn render_body(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        match self.status {
            ProjectStatus::Failed => self.render_failed(tokens, cx),
            _ if self.project.is_none() => {
                let message = if self.status == ProjectStatus::Loading {
                    tr("Scanning Maven project...")
                } else {
                    tr("No Maven project detected")
                };
                empty_state(tokens, message)
            }
            _ => self.render_tree(tokens, cx),
        }
    }

    fn render_failed(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let error = self
            .error
            .clone()
            .unwrap_or_else(|| tr("Unable to load Maven project").into());
        v_flex()
            .size_full()
            .min_h(px(0.0))
            .items_center()
            .justify_center()
            .gap(px(8.0))
            .child(
                icon(LitheIcon::Warning)
                    .with_size(px(28.0))
                    .text_color(tokens.error),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::UI_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.primary_text)
                    .child(tr("Unable to load Maven project")),
            )
            .child(
                div()
                    .max_w(px(420.0))
                    .px(px(16.0))
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(error),
            )
            .child(
                Button::new("lithe-maven:retry")
                    .small()
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .label(tr("Retry"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.load_project(cx);
                    })),
            )
            .into_any_element()
    }

    fn render_tree(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let Some(project) = self.project.as_ref() else {
            return empty_state(tokens, tr("No Maven project detected"));
        };

        let mut rows: Vec<AnyElement> = Vec::new();
        if !project.profiles.is_empty() || !self.custom_profiles.is_empty() {
            rows.push(self.render_profiles(project, tokens, cx));
        }
        rows.push(self.render_module_node(
            &project.modules,
            &project.relative_path,
            &project.artifact_id,
            project.packaging.clone(),
            &project.source_roots,
            None,
            tokens,
            cx,
        ));
        // 顶级模块只在根节点展开后嵌套渲染。之前这里把它们又平铺成根节点的
        // 兄弟行，两份节点共用同一个 `module:{path}` id：展开其中一份后，
        // 点击另一份会把 id 从 `expanded` 里移除，表现为「模块展开不了」。

        v_flex()
            .id("lithe-maven-tree")
            .size_full()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .overflow_y_scroll()
            .bg(tokens.sidebar)
            .p(px(TREE_PADDING))
            .gap(px(1.0))
            .children(rows)
            .into_any_element()
    }

    fn render_profiles(
        &self,
        project: &MavenProject,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let expanded = self.expanded.contains("profiles");
        let header = self.render_group_row(
            "profiles",
            tr("Profiles"),
            LitheIcon::Folder,
            expanded,
            tokens,
            cx,
        );
        let mut column = v_flex().gap(px(1.0)).child(header);
        if expanded {
            let mut entries = v_flex().gap(px(1.0)).pl(px(TREE_INDENT));
            for profile in &project.profiles {
                entries = entries.child(self.render_profile_entry(&profile.id, tokens, cx));
            }
            for id in &self.custom_profiles {
                if project.profiles.iter().all(|profile| &profile.id != id) {
                    entries = entries.child(self.render_profile_entry(id, tokens, cx));
                }
            }
            entries = entries
                .child(
                    Button::new("lithe-maven:add-profile")
                        .ghost()
                        .small()
                        .rounded(px(LitheMetrics::CONTROL_RADIUS))
                        .icon(icon(LitheIcon::Plus))
                        .label(tr("Add Maven profile"))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.open_profile_dialog(window, cx);
                        })),
                )
                .child(
                    Button::new("lithe-maven:restore-profiles")
                        .ghost()
                        .small()
                        .rounded(px(LitheMetrics::CONTROL_RADIUS))
                        .icon(icon(LitheIcon::Restore))
                        .label(tr("Restore default profiles"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.restore_default_profiles(cx);
                        })),
                );
            column = column.child(entries);
        }
        column.into_any_element()
    }

    fn render_profile_entry(
        &self,
        id: &str,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let checked = self.selected_profiles.contains(id);
        let profile_id = id.to_string();
        h_flex()
            .id(SharedString::from(format!("lithe-maven:profile:{id}")))
            .h(px(TREE_ROW_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(8.0))
            .px(px(8.0))
            .rounded(px(4.0))
            .hover(|style| style.bg(tokens.hover))
            .cursor_pointer()
            .on_click(cx.listener(move |this, _, _, cx| {
                this.toggle_profile(profile_id.clone(), cx);
            }))
            .child(
                Checkbox::new(SharedString::from(format!(
                    "lithe-maven:profile-check:{id}"
                )))
                .small()
                .checked(checked),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(id.to_string()),
            )
            .into_any_element()
    }

    /// 一个模块（含反应堆根）的完整子树。
    fn render_module_tree(
        &self,
        module: &Module,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.render_module_node(
            &module.modules,
            &module.relative_path,
            &module.artifact_id,
            module.relative_path.clone(),
            &module.source_roots,
            Some(module),
            tokens,
            cx,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn render_module_node(
        &self,
        child_modules: &[Module],
        node_path: &str,
        artifact_id: &str,
        packaging: String,
        source_roots: &[SourceRoot],
        module: Option<&Module>,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let node_id = SharedString::from(format!(
            "{}:{node_path}",
            if module.is_some() {
                "module"
            } else {
                "project"
            }
        ));
        let expanded = self.expanded.contains(node_id.as_ref());
        // Tauri 的项目根在 `selectedModule === null` 时选中。
        let selected = if module.is_some() {
            self.selected_module.as_deref() == Some(node_path)
        } else {
            self.selected_module.is_none()
        };

        let mut header = self.render_node_row(
            node_id.clone(),
            artifact_id,
            Some(packaging),
            LitheIcon::Package,
            tokens.accent,
            expanded,
            selected,
            true,
            tokens,
            cx,
        );
        // 单击模块节点切换选中。
        let select_path = node_path.to_string();
        header = header.on_click(cx.listener(move |this, _, _, cx| {
            this.select_module(Some(select_path.clone()), cx);
        }));
        // 模块节点的右键菜单；反应堆根同样有（module_path = "."）。
        let menu_module = module.is_some().then(|| node_path.to_string());
        let menu_path = node_path.to_string();
        header = header.on_mouse_down(
            gpui_kit::MouseButton::Right,
            cx.listener(move |this, event: &gpui_kit::MouseDownEvent, window, cx| {
                let module = menu_module.clone();
                let path = menu_path.clone();
                this.open_node_menu(module, path, event.position, window, cx);
            }),
        );

        let mut column = v_flex().gap(px(1.0)).child(header);
        if expanded {
            let module_path = node_path.to_string();
            let mut children = v_flex().gap(px(1.0)).pl(px(TREE_INDENT));
            // 没有（pom 聚合模块常见）源码根时整组不显示，对齐 Tauri。
            if !source_roots.is_empty() {
                children =
                    children.child(self.render_source_roots(&node_id, source_roots, tokens, cx));
            }
            children =
                children.child(self.render_lifecycle(&node_id, module_path.clone(), tokens, cx));
            children = children.child(self.render_dependencies(&node_id, module_path, tokens, cx));
            for child in child_modules {
                children = children.child(self.render_module_tree(child, tokens, cx));
            }
            column = column.child(children);
        }

        column.into_any_element()
    }

    /// 源码根分组。
    fn render_source_roots(
        &self,
        owner_id: &str,
        roots: &[SourceRoot],
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let group_id = SharedString::from(format!("{owner_id}:source-roots"));
        let expanded = self.expanded.contains(group_id.as_ref());
        let header = self.render_group_row(
            group_id.as_ref(),
            tr("Source Roots"),
            LitheIcon::Folder,
            expanded,
            tokens,
            cx,
        );
        let mut column = v_flex().gap(px(1.0)).child(header);
        if expanded {
            let mut entries = v_flex().gap(px(1.0)).pl(px(TREE_INDENT));
            for root in roots {
                entries = entries.child(self.render_source_root_row(root, tokens));
            }
            if roots.is_empty() {
                entries = entries.child(self.render_placeholder_row(tr("No source roots"), tokens));
            }
            column = column.child(entries);
        }
        column.into_any_element()
    }

    fn render_source_root_row(&self, root: &SourceRoot, tokens: LitheTokens) -> AnyElement {
        let color = match root.kind.tone() {
            SourceRootTone::Primary => tokens.accent,
            SourceRootTone::Success => tokens.success,
            SourceRootTone::Warning => tokens.warning,
        };
        h_flex()
            .h(px(TREE_ROW_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(6.0))
            .px(px(8.0))
            .child(
                icon(LitheIcon::Folder)
                    .with_size(px(14.0))
                    .text_color(color),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(root.path.clone()),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(root.kind.title()),
            )
            .into_any_element()
    }

    /// 生命周期分组：单行阶段，单击选中、双击运行。
    fn render_lifecycle(
        &self,
        owner_id: &str,
        module_path: String,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let group_id = SharedString::from(format!("{owner_id}:lifecycle"));
        let expanded = self.expanded.contains(group_id.as_ref());
        let header = self.render_group_row(
            group_id.as_ref(),
            tr("Lifecycle"),
            LitheIcon::Settings,
            expanded,
            tokens,
            cx,
        );
        let mut column = v_flex().gap(px(1.0)).child(header);
        if expanded {
            let mut entries = v_flex().gap(px(1.0)).pl(px(TREE_INDENT));
            for phase in model::LIFECYCLE_PHASES {
                let selected = self.selected_module.as_deref() == Some(module_path.as_str())
                    && self.selected_phase == phase;
                entries = entries.child(self.render_phase_row(
                    module_path.clone(),
                    phase,
                    selected,
                    tokens,
                    cx,
                ));
            }
            column = column.child(entries);
        }
        column.into_any_element()
    }

    fn render_phase_row(
        &self,
        module_path: String,
        phase: &'static str,
        selected: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let click_module = module_path.clone();
        let run_module = module_path.clone();
        let menu_module = module_path.clone();
        let menu_phase = phase;
        h_flex()
            .id(SharedString::from(format!(
                "lithe-maven:phase:{phase}:{module_path}"
            )))
            .h(px(TREE_ROW_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(6.0))
            .px(px(8.0))
            .rounded(px(4.0))
            .when(selected, |this| this.bg(tokens.selection))
            .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
            .cursor_pointer()
            .on_click(cx.listener(move |this, event: &ClickEvent, _, cx| {
                // 单击只选中；双击立即运行（对齐 Tauri 的 onClick / onDoubleClick）。
                this.select_phase(Some(click_module.clone()), phase, cx);
                if event.click_count() >= 2 {
                    this.run_goals(
                        vec![phase.to_string()],
                        Some(run_module.clone()),
                        phase.to_string(),
                        cx,
                    );
                }
            }))
            .on_mouse_down(
                gpui_kit::MouseButton::Right,
                cx.listener(move |this, event: &gpui_kit::MouseDownEvent, window, cx| {
                    let module = menu_module.clone();
                    let owner = cx.weak_entity();
                    let popup = PopupMenu::build(window, cx, move |menu, _window, _cx| {
                        menu.item(PopupMenuItem::new(tr("Run this lifecycle phase")).on_click(
                            move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    let module = module.clone();
                                    this.run_goals(
                                        vec![menu_phase.to_string()],
                                        Some(module),
                                        menu_phase.to_string(),
                                        cx,
                                    );
                                });
                            },
                        ))
                    });
                    this.show_popup(popup, event.position, window, cx);
                }),
            )
            .child(
                icon(LitheIcon::Run)
                    .with_size(px(12.0))
                    .text_color(if selected {
                        white()
                    } else {
                        tokens.secondary_text
                    }),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(if selected {
                        white()
                    } else {
                        tokens.secondary_text
                    })
                    .child(phase),
            )
            .into_any_element()
    }

    /// 依赖项分组。展开时才解析；状态行显示加载 / 失败 / 取消 / 空结果。
    fn render_dependencies(
        &self,
        owner_id: &str,
        module_path: String,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let group_id = SharedString::from(format!("{owner_id}:dependencies"));
        let expanded = self.expanded.contains(group_id.as_ref());
        let header = self.render_group_row(
            group_id.as_ref(),
            tr("Dependencies"),
            LitheIcon::Package,
            expanded,
            tokens,
            cx,
        );
        let mut column = v_flex().gap(px(1.0)).child(header);
        if expanded {
            let mut entries = v_flex().gap(px(1.0)).pl(px(TREE_INDENT));
            match self.dependency_loads.get(&module_path) {
                Some(DependencyLoad::Loading) => {
                    let cancel_module = module_path.clone();
                    entries =
                        entries.child(
                            h_flex()
                                .h(px(TREE_ROW_HEIGHT))
                                .w_full()
                                .items_center()
                                .gap(px(6.0))
                                .px(px(8.0))
                                .child(
                                    div()
                                        .min_w(px(0.0))
                                        .flex_1()
                                        .truncate()
                                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                        .text_color(tokens.secondary_text)
                                        .child(tr("Resolving dependencies...")),
                                )
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "lithe-maven:dep-cancel:{module_path}"
                                    )))
                                    .ghost()
                                    .small()
                                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        let module = cancel_module.clone();
                                        this.cancel_dependency_load(&module, cx);
                                    })),
                                ),
                        );
                }
                Some(DependencyLoad::Failed(error)) => {
                    let error_text = error.clone();
                    let retry_module = module_path.clone();
                    entries =
                        entries.child(
                            h_flex()
                                .h(px(TREE_ROW_HEIGHT))
                                .w_full()
                                .items_center()
                                .gap(px(6.0))
                                .px(px(8.0))
                                .child(
                                    icon(LitheIcon::Warning)
                                        .with_size(px(14.0))
                                        .text_color(tokens.error),
                                )
                                .child(
                                    div()
                                        .min_w(px(0.0))
                                        .flex_1()
                                        .truncate()
                                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                        .text_color(tokens.secondary_text)
                                        .child(error_text),
                                )
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "lithe-maven:dep-retry:{module_path}"
                                    )))
                                    .ghost()
                                    .small()
                                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                                    .label(tr("Retry"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        let module = retry_module.clone();
                                        this.load_dependencies(module, cx);
                                    })),
                                ),
                        );
                }
                Some(DependencyLoad::Cancelled) => {
                    let retry_module = module_path.clone();
                    entries =
                        entries.child(
                            h_flex()
                                .h(px(TREE_ROW_HEIGHT))
                                .w_full()
                                .items_center()
                                .gap(px(6.0))
                                .px(px(8.0))
                                .child(
                                    div()
                                        .min_w(px(0.0))
                                        .flex_1()
                                        .truncate()
                                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                        .text_color(tokens.warning)
                                        .child(tr("Dependency resolution cancelled")),
                                )
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "lithe-maven:dep-retry:{module_path}"
                                    )))
                                    .ghost()
                                    .small()
                                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                                    .label(tr("Retry"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        let module = retry_module.clone();
                                        this.load_dependencies(module, cx);
                                    })),
                                ),
                        );
                }
                Some(DependencyLoad::Ready(dependencies)) if dependencies.is_empty() => {
                    entries =
                        entries.child(self.render_placeholder_row(tr("No dependencies"), tokens));
                }
                Some(DependencyLoad::Ready(dependencies)) => {
                    let owner = owner_id.to_string();
                    for (index, dependency) in dependencies.iter().enumerate() {
                        entries = entries.child(self.render_dependency_row(
                            &owner,
                            &format!("{owner_id}:dep:{index}"),
                            dependency,
                            tokens,
                            cx,
                        ));
                    }
                }
                None => {
                    entries = entries.child(
                        self.render_placeholder_row(tr("No resolved dependency snapshot"), tokens),
                    );
                }
            }
            column = column.child(entries);
        }
        column.into_any_element()
    }

    fn render_dependency_row(
        &self,
        owner_id: &str,
        node_id: &str,
        dependency: &Dependency,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let expanded = self.expanded.contains(node_id);
        let has_children = !dependency.children.is_empty();
        let pom_module = dependency.module_path.clone();
        let mut row = self.render_node_row(
            SharedString::from(node_id.to_string()),
            &dependency.artifact_id,
            Some(dependency.subtitle()),
            if dependency.resolution.is_omitted() {
                LitheIcon::Warning
            } else {
                LitheIcon::Package
            },
            if dependency.resolution.is_omitted() {
                tokens.warning
            } else {
                tokens.accent
            },
            expanded,
            false,
            has_children,
            tokens,
            cx,
        );
        // 单击依赖项打开所属模块的 pom.xml，对齐 Tauri。
        row = row.on_click(cx.listener(move |this, _, window, cx| {
            let module = pom_module.clone();
            this.open_pom(&module, window, cx);
        }));
        let mut column = v_flex().gap(px(1.0)).child(row);
        if expanded && has_children {
            let mut children = v_flex().gap(px(1.0)).pl(px(TREE_INDENT));
            for (index, child) in dependency.children.iter().enumerate() {
                children = children.child(self.render_dependency_row(
                    owner_id,
                    &format!("{node_id}:{index}"),
                    child,
                    tokens,
                    cx,
                ));
            }
            column = column.child(children);
        }
        column.into_any_element()
    }

    // -----------------------------------------------------------------------
    // 行原语
    // -----------------------------------------------------------------------

    /// 分组行（可折叠的组标题）。
    fn render_group_row(
        &self,
        id: &str,
        title: &'static str,
        node_icon: LitheIcon,
        expanded: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let toggle_id = id.to_string();
        div()
            .id(SharedString::from(format!("lithe-maven:group:{id}")))
            .h(px(TREE_ROW_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .flex()
            .items_center()
            .gap(px(2.0))
            .px(px(4.0))
            .rounded(px(4.0))
            .hover(|style| style.bg(tokens.hover))
            .cursor_pointer()
            .on_click(cx.listener(move |this, _, _, cx| {
                this.toggle_expanded(&toggle_id.clone(), cx);
            }))
            .child(chevron(expanded, tokens))
            .child(
                icon(node_icon)
                    .with_size(px(14.0))
                    .text_color(tokens.accent),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(title),
            )
    }

    /// 树节点行：折叠箭头 + 图标 + 标题 + 副标题。
    #[allow(clippy::too_many_arguments)]
    fn render_node_row(
        &self,
        id: SharedString,
        title: &str,
        subtitle: Option<String>,
        node_icon: LitheIcon,
        icon_color: gpui_kit::Hsla,
        expanded: bool,
        selected: bool,
        has_children: bool,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let toggle_id = id.to_string();
        // 箭头元素先独立构建：`.when` 闭包不能改变元素类型，有子节点时它
        // 是可点击的 Stateful 元素，没有时只是占位。
        let chevron_element: AnyElement = if has_children {
            div()
                .id(SharedString::from(format!(
                    "lithe-maven:chevron:{toggle_id}"
                )))
                .w_full()
                .h_full()
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .on_click(cx.listener(move |this, _, _, cx| {
                    // 箭头自身的点击不要冒泡成整行选中。
                    cx.stop_propagation();
                    this.toggle_expanded(&toggle_id.clone(), cx);
                }))
                .child(chevron(expanded, tokens))
                .into_any_element()
        } else {
            div().into_any_element()
        };
        let mut row = div()
            .id(id)
            .h(px(TREE_ROW_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .flex()
            .items_center()
            .gap(px(2.0))
            .px(px(4.0))
            .rounded(px(4.0))
            .when(selected, |this| this.bg(tokens.selection))
            .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
            .cursor_pointer()
            .child(
                div()
                    .w(px(14.0))
                    .h_full()
                    .flex_shrink_0()
                    .child(chevron_element),
            )
            .child(icon(node_icon).with_size(px(14.0)).text_color(if selected {
                white()
            } else {
                icon_color
            }))
            .child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(if selected {
                        white()
                    } else {
                        tokens.primary_text
                    })
                    .child(title.to_string()),
            );
        if let Some(subtitle) = subtitle {
            row = row.child(
                div()
                    .min_w(px(0.0))
                    .ml(px(4.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(if selected {
                        white()
                    } else {
                        tokens.tertiary_text
                    })
                    .child(subtitle),
            );
        }
        row
    }

    fn render_placeholder_row(&self, message: &'static str, tokens: LitheTokens) -> AnyElement {
        div()
            .h(px(TREE_ROW_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .flex()
            .items_center()
            .px(px(8.0))
            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
            .text_color(tokens.tertiary_text)
            .child(message)
            .into_any_element()
    }
}

fn chevron(expanded: bool, tokens: LitheTokens) -> AnyElement {
    icon(if expanded {
        LitheIcon::ChevronDown
    } else {
        LitheIcon::ChevronRight
    })
    .with_size(px(12.0))
    .text_color(tokens.tertiary_text)
    .into_any_element()
}

fn empty_state(tokens: LitheTokens, message: &'static str) -> AnyElement {
    div()
        .size_full()
        .min_h(px(0.0))
        .flex()
        .items_center()
        .justify_center()
        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
        .text_color(tokens.secondary_text)
        .child(message)
        .into_any_element()
}

fn cancelled_output(output: &str) -> String {
    let separator = if output.is_empty() || output.ends_with('\n') {
        ""
    } else {
        "\n"
    };
    format!("{separator}{}\n", tr("Maven task cancelled."))
}

/// 依赖分组 id 的 owner 形如 `project:.` / `module:service`；反解出模块路径。
fn owner_module_path(owner: &str) -> String {
    owner
        .split_once(':')
        .map(|(_, path)| path.to_string())
        .unwrap_or_else(|| owner.to_string())
}

/// 工作区根转成 Core 需要的 UTF-8 字符串。
fn root_text(root: &std::path::Path) -> String {
    root.to_string_lossy().to_string()
}

fn normalize_root(root: PathBuf) -> Option<PathBuf> {
    if root.as_os_str().is_empty() {
        None
    } else if root.is_dir() {
        Some(root)
    } else {
        None
    }
}
